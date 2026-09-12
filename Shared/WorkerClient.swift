import Foundation
import Security

enum CredentialStore {
    private static let service = "JP-Live.worker"
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ value: String, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if update == errSecItemNotFound {
            var item = query; attrs.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AppFailure.message("Keychain 저장 실패") }
        } else if update != errSecSuccess { throw AppFailure.message("Keychain 갱신 실패") }
    }
}

actor WorkerClient {
    static let shared = WorkerClient()
    static let base = URL(string: "https://jp-translator-api.rlaalsrbr.workers.dev")!
    private var cachedToken: String?
    private var expiration = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var configurationID = UUID()

    func configure(appToken: String) throws {
        let value = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppFailure.message("APP_TOKEN이 비어 있습니다.") }
        try CredentialStore.set(value, key: "app")
        configurationID = UUID()
        refreshTask?.cancel(); refreshTask = nil; cachedToken = nil; expiration = .distantPast
    }
    func logToken(force: Bool = false) async throws -> String {
        if !force, let cachedToken, expiration.timeIntervalSinceNow > 300 { return cachedToken }
        let issuedFor = configurationID
        if let refreshTask {
            let token = try await refreshTask.value
            guard issuedFor == configurationID else { throw CancellationError() }
            return token
        }
        let task = Task<String, Error> {
            guard let master = CredentialStore.get("app"), !master.isEmpty else {
                throw AppFailure.message("… → 설정에서 기존 APP_TOKEN을 한 번 입력하세요.")
            }
            var req = URLRequest(url: Self.base.appendingPathComponent("auth/open-token"))
            req.httpMethod = "POST"; req.timeoutInterval = 30
            req.setValue(master, forHTTPHeaderField: "x-app-token")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
            let (data, response) = try await URLSession.shared.data(for: req)
            try Task.checkCancellation()
            try Self.check(response)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let token = object?["log_token"] as? String, !token.isEmpty else { throw AppFailure.message("인증 응답 오류") }
            return token
        }
        refreshTask = task
        do {
            let token = try await task.value
            guard issuedFor == configurationID else { throw CancellationError() }
            cachedToken = token; expiration = Date().addingTimeInterval(24 * 3600)
            refreshTask = nil; return token
        } catch { if issuedFor == configurationID { refreshTask = nil }; throw error }
    }
    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AppFailure.message("서버 응답 오류") }
        guard (200..<300).contains(http.statusCode) else { throw AppFailure.message("서버 요청 실패 (\(http.statusCode))") }
    }
    func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        for attempt in 0..<2 {
            let token = try await logToken(force: attempt == 1)
            try Task.checkCancellation()
            guard let url = URL(string: path, relativeTo: Self.base)?.absoluteURL,
                  url.host == Self.base.host, url.scheme == "https" else { throw AppFailure.message("잘못된 API 주소") }
            var req = URLRequest(url: url); req.timeoutInterval = 45
            req.setValue(token, forHTTPHeaderField: "x-log-token")
            if let body {
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: req)
            if (response as? HTTPURLResponse)?.statusCode == 401 && attempt == 0 { continue }
            try Self.check(response); return data
        }
        throw AppFailure.message("인증 갱신에 실패했습니다.")
    }
    func translate(_ text: String, language: SourceLanguage) async throws -> String {
        let data = try await request("/run/translate", body: ["text":text,"src":language.code,"tgt":"KO","target":"KO"])
        struct Result: Decodable { var translation: String }
        return try JSONDecoder().decode(Result.self, from: data).translation
    }
    struct Reconstruction: Decodable { var translation: String; var units: [WordToken] }
    func reconstruct(_ caption: Caption, translation: String, tokens: [WordToken]) async throws -> Reconstruction {
        guard caption.language == .japanese else { throw AppFailure.message("AI 재구성은 일본어 전용입니다.") }
        let morphs = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tokens))
        let data = try await request("/run/restructure", body: ["text":caption.source,"deepl_translation":translation,"morphs":morphs])
        let result = try JSONDecoder().decode(Reconstruction.self, from: data)
        guard result.units.map(\.surface).joined() == caption.source else { throw AppFailure.message("AI 결과의 원문이 일치하지 않습니다.") }
        return result
    }
    func sessions(query: String = "") async throws -> [LearningSession] {
        struct Result: Decodable { var sessions: [LearningSession] }
        var components = URLComponents()
        components.path = "/api/sessions/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let path = query.isEmpty ? "/api/sessions/recent" : components.string!
        return try JSONDecoder().decode(Result.self, from: await request(path)).sessions
    }
    func resolve(_ input: String) async throws -> LearningSession {
        struct Result: Decodable { var session: LearningSession }
        return try JSONDecoder().decode(Result.self, from: await request("/api/sessions/resolve", body: ["input":input])).session
    }
    func save(_ payload: [String: Any]) async throws {
        // Only 401 retries automatically; network timeouts may have committed a save already.
        _ = try await request("/api/save", body: payload)
    }
}
