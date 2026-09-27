import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var message = ""
    @State private var busy = false
    #if PHASE2
    @State private var deviceValidation = false
    #endif
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
                Section("일본어 형태소 분할") {
                    Picker("분할 단위", selection: Binding(get: { model.splitMode }, set: { model.setSplitMode($0) })) {
                        ForEach(SudachiSplitMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented)
                    Text("A: 짧게 · B: 중간 · C: 길게(기본값). 변경하면 일본어 자막과 팝업을 다시 분석합니다.").font(.caption)
                    Text(model.morphologyStatus).font(.caption)
                }
                Section("입력 및 처리 상태") {
                    Text("소스 버전 · local-stage7-2026-09-21").font(.caption)
                    LabeledContent("입력 RMS", value: String(format: "%.1f dBFS", model.metrics.rmsDB))
                    LabeledContent("입력 peak", value: String(format: "%.1f dBFS", model.metrics.peakDB))
                    LabeledContent("보정 gain", value: String(format: "%.1f dB", model.metrics.gainDB))
                    Text(model.featureStatus)
                    ForEach(model.metrics.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    Text(LocalTokenizer.engineName)
                    Text(model.separationDiagnostics.status).font(.caption)
                    Text("분리 시도 \(model.separationDiagnostics.attempted) · 반영 \(model.separationDiagnostics.completed) · 생략 \(model.separationDiagnostics.skipped) · 실패 \(model.separationDiagnostics.failures) · 과부하 중단 \(model.separationDiagnostics.overloadStops)").font(.caption)
                    if let data = try? JSONEncoder().encode(model.separationDiagnostics), let json = String(data: data, encoding: .utf8) {
                        ShareLink("분리 진단 공유", item: json)
                    }
                    #if PHASE2
                    Text("Phase 2 · iOS 27 시스템 캡처")
                    Button("기기 검증", systemImage: "stethoscope") { deviceValidation = true }
                        .disabled(model.running)
                    #else
                    Text("Phase 1 · 파일 오디오 입력 · 시스템 캡처는 Phase 2")
                    #endif
                }
                Section("실시간 지연 진단") {
                    let value = model.liveDiagnostics
                    LabeledContent("실행 시간", value: String(format: "%.1f초", value.elapsed))
                    LabeledContent("빠른 STT 원본 시각 차이", value: String(format: "%.3f초", value.input.sourceBacklog))
                    LabeledContent("입력 대기 오디오", value: String(format: "%.3f초 · 최대 %.3f초", value.input.pendingAudio, value.input.peakPendingAudio))
                    LabeledContent("보정 입력 대기열", value: String(format: "%.3f초 · 최대 %.3f초", value.quality.backlog, value.quality.peakBacklog))
                    LabeledContent("보정 수신 / STT 전달", value: sourceTime(value.quality.acceptedThrough) + " / " + sourceTime(value.quality.analyzerInputThrough))
                    LabeledContent("보정 인식 결과 시각", value: sourceTime(value.quality.recognitionThrough))
                    LabeledContent("보정 생략 버퍼", value: String(value.quality.skippedChunks))
                    LabeledContent("보정 과부하 중단", value: String(value.quality.overloadStops))
                    LabeledContent("적용한 자막 보정", value: String(value.qualityRevisions))
                    LabeledContent("화자 분석 연결 시각", value: sourceTime(value.quality.analysisActivatedAt))
                    LabeledContent("음성 개선 연결 시각", value: sourceTime(value.quality.enhancementActivatedAt))
                    LabeledContent("보관 자막", value: String(value.captionCount))
                    if let reason = value.quality.stoppedReason { Text(reason).foregroundStyle(.orange) }
                    Text("빠른 STT 지연은 입력 전달 기준입니다. 보정 대기열 수치는 내부 분석 대기·Apple 인식 시간을 제외하므로 수신/전달/인식 시각도 함께 확인하세요. 생략 수에는 모델 준비 전과 보정 중단 후의 버퍼가 포함됩니다.").font(.caption)
                    ShareLink("진단값 공유", item: diagnosticsJSON)
                }
            }.navigationTitle("설정").toolbar { Button("완료") { dismiss() } }
        }
        #if PHASE2
        .sheet(isPresented: $deviceValidation) {
            DeviceValidationView(language: model.language)
        }
        #endif
    }
    private func sourceTime(_ value: Double?) -> String {
        value.map { String(format: "원본 %.2f초", $0) } ?? "아직 연결되지 않음"
    }
    private var diagnosticsJSON: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(model.liveDiagnostics) else { return "진단값 직렬화 실패" }
        return String(decoding: data, as: UTF8.self)
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


struct DictionaryScreen: View {
    let term: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            DictionaryWebView(url: url)
                .navigationTitle(term)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("닫기") { dismiss() } }
        }
        .presentationDetents([.large])
    }
}

struct DictionaryWebView: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { uiView.stopLoading() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "https" || url.scheme == "http" || url.scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
