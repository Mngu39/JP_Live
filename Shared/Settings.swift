import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("기존 서비스 연결") {
                    SecureField("기존 APP_TOKEN", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Keychain에 저장하고 연결 확인") {
                        Task {
                            busy = true; defer { busy = false }
                            do {
                                try await WorkerClient.shared.configure(appToken: token)
                                _ = try await WorkerClient.shared.logToken(force: true)
                                token = ""; message = "연결됨 · log token 자동 갱신"
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(token.isEmpty || busy)
                    if !message.isEmpty { Text(message).font(.caption) }
                    Text("DeepL 키를 새로 만들 필요가 없습니다. 기존 Worker의 APP_TOKEN을 입력하세요.").font(.caption)
                }
                Section("학습 데이터 확인") {
                    ForEach(LearningData.resourceStatus, id: \.self) { Text($0).font(.caption) }
                }
                Section("입력 및 처리 상태") {
                    Text("소스 버전 · audio-timeline-2026-09-10").font(.caption)
                    LabeledContent("입력 RMS", value: String(format: "%.1f dBFS", model.metrics.rmsDB))
                    LabeledContent("입력 peak", value: String(format: "%.1f dBFS", model.metrics.peakDB))
                    LabeledContent("보정 gain", value: String(format: "%.1f dB", model.metrics.gainDB))
                    Text(model.featureStatus)
                    ForEach(model.metrics.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    Text(LocalTokenizer.engineName)
                    Text("음성 분리 모델은 별도 준비가 필요합니다. 미연결 상태에서는 혼합음 STT를 유지합니다.").font(.caption)
                    #if PHASE2
                    Text("Phase 2 · iOS 27 시스템 캡처")
                    #else
                    Text("Phase 1 · 파일 오디오 입력 · 시스템 캡처는 Phase 2")
                    #endif
                }
            }.navigationTitle("설정").toolbar { Button("완료") { dismiss() } }
        }
    }
}

struct LogsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var token: String?
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Group {
                if let token { LogsWebView(token: token) }
                else if !error.isEmpty { Text(error).padding() }
                else { ProgressView("단어장 연결 중…") }
            }
            .navigationTitle("단어장").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("닫기") { dismiss() } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    do {
                        let current = try await WorkerClient.shared.logToken()
                        try Task.checkCancellation()
                        token = current; error = ""
                    } catch { if Task.isCancelled { return }; self.error = error.localizedDescription }
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
        }
    }
}

struct LogsWebView: UIViewRepresentable {
    let token: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.token = token
        // Existing page consumes the short-lived token from fragment and removes it.
        var url = URLComponents(string: "https://mngu39.github.io/JP_Translator/logs.html")!
        url.fragment = "log_token=" + token
        web.load(URLRequest(url: url.url!))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.token = token
        context.coordinator.applyToken(to: uiView)
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { uiView.stopLoading() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var token = ""
        func applyToken(to web: WKWebView) {
            guard web.url?.scheme == "https", web.url?.host == "mngu39.github.io",
                  web.url?.path.hasPrefix("/JP_Translator/") == true,
                  let data = try? JSONSerialization.data(withJSONObject: [token]) else { return }
            let array = String(decoding: data, as: UTF8.self)
            web.evaluateJavaScript("localStorage.setItem('jpTranslatorLogToken', (\(array))[0])", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { applyToken(to: webView) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "about" || (url.scheme == "https" && url.host == "mngu39.github.io" && url.path.hasPrefix("/JP_Translator/")) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if url.scheme == "https" { UIApplication.shared.open(url) }
            }
        }
    }
}
