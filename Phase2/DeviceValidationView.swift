import SwiftUI

@MainActor
struct DeviceValidationView: View {
    let language: SourceLanguage
    @StateObject private var controller = DeviceValidationController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("사용 방법") {
                    Text("1. 검증 시작 → 화면 전체 공유를 선택")
                    Text("2. 유튜브 등에서 실제 음성/대사를 20~30초 재생")
                    Text("3. 실제 PCM 약 5초 후 저장과 같은 두 번째 고해상도 스크린샷 스트림을 자동 실행합니다")
                    Text("4. 스크린샷 뒤 최소 5초 이상 계속 재생한 다음 이 앱으로 돌아와 검증 정지")
                    Text("5. 같은 과정을 한 번 더 실행하면 stop → restart와 시간축 초기화까지 검증")
                    Text("전사 문장은 저장하지 않고 PCM/STT 수치와 PASS/FAIL만 JSON에 기록합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("현재 상태") {
                    LabeledContent("언어", value: language.title)
                    LabeledContent("상태", value: controller.status)
                    LabeledContent("완료 세션", value: "\(controller.sessions.count)")
                    LabeledContent("전체 판정", value: verdictTitle(controller.combinedReport.overallVerdict))
                    LabeledContent("재시작", value: verdictTitle(controller.combinedReport.restartCheck.verdict))
                }

                if let latest = controller.sessions.last {
                    Section("최근 세션") {
                        LabeledContent("판정", value: verdictTitle(latest.verdict))
                        LabeledContent("raw PCM", value: "\(latest.rawChunks) chunks · \(String(format: "%.2f", latest.rawAudioDuration)) s")
                        LabeledContent("전처리 PCM", value: "\(latest.processedChunks) chunks · \(String(format: "%.2f", latest.processedAudioDuration)) s")
                        LabeledContent("Analyzer 입력", value: "\(latest.analyzerChunks) chunks · \(String(format: "%.2f", latest.analyzerAudioDuration)) s")
                        LabeledContent("STT 결과", value: "\(latest.speechResults) · final \(latest.finalSpeechResults)")
                        LabeledContent("스크린샷 연속성", value: verdictTitle(latest.screenshotContinuity.verdict))
                        ForEach(latest.checks) { check in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(check.name).font(.caption.monospaced())
                                    Spacer()
                                    Text(verdictTitle(check.verdict)).font(.caption).bold()
                                }
                                Text(check.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("실행") {
                    if controller.running {
                        Button("검증 정지", systemImage: "stop.fill") {
                            Task { await controller.stop() }
                        }
                    } else {
                        Button("검증 시작", systemImage: "play.fill") {
                            controller.start(language: language)
                        }
                    }

                    if let url = controller.reportURL {
                        ShareLink(item: url) {
                            Label("JSON 보고서 공유", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !controller.exportError.isEmpty {
                        Text("보고서 생성 오류: \(controller.exportError)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Button("검증 기록 초기화", role: .destructive) {
                        controller.reset()
                    }.disabled(controller.running || controller.sessions.isEmpty)
                }
            }
            .navigationTitle("기기 검증")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("닫기") { dismiss() }.disabled(controller.running) }
        }
        .interactiveDismissDisabled(controller.running)
        .onDisappear {
            if controller.running { Task { await controller.stop() } }
        }
    }

    private func verdictTitle(_ value: DeviceValidationVerdict) -> String {
        switch value {
        case .pass: return "PASS"
        case .warning: return "WARNING"
        case .fail: return "FAIL"
        case .notTested: return "NOT TESTED"
        }
    }
}
