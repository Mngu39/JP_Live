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
                    Text("2. 유튜브 등에서 서로 다른 두 사람이 번갈아 말하는 실제 음성을 20~30초 재생")
                    Text("3. 실제 PCM 약 5초 후 현재 오디오 SCStream에 screen output을 잠깐 붙여 고해상도 프레임 1장을 받고 즉시 제거합니다")
                    Text("4. 두 사람이 실제로 겹쳐 말하기 직전에 ‘겹쳐 말하기 시작’, 끝난 직후 ‘겹쳐 말하기 종료’를 눌러 expected overlap 구간을 기록")
                    Text("5. 스크린샷 뒤 최소 5초 이상 계속 재생한 다음 이 앱으로 돌아와 검증 정지")
                    Text("6. 두 세션 모두 '검증 정지'로 직접 종료하고 다시 시작해야 stop → restart 검증이 PASS합니다")
                    Text("진단을 위해 최근 Apple STT callback 원문을 최대 48개까지 JSON에 함께 기록합니다. 공유 전에 내용에 민감한 대화가 없는지 확인하세요.")
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
                        LabeledContent("STT 결과", value: "\(latest.speechResults) callbacks · text \(latest.semanticSpeechResults) · timed-invalid \(latest.invalidTimedSpeechResults)")
                        LabeledContent("화자 분석", value: latest.diarization.status)
                        LabeledContent("화자 slot", value: latest.diarization.distinctSpeakerSlots.map(String.init).joined(separator: ", ").isEmpty ? "없음" : latest.diarization.distinctSpeakerSlots.map(String.init).joined(separator: ", "))
                        LabeledContent("화자 모델", value: latest.diarizerModelBundled ? "BUNDLED" : "MISSING")
                        LabeledContent("분리 모델", value: latest.separatorModelBundled ? "BUNDLED" : "MISSING")
                        LabeledContent("same-stream 스크린샷", value: latest.screenshotContinuity.succeeded ? "SUCCESS" : (latest.screenshotContinuity.attempted ? "FAIL" : "NOT TESTED"))
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
                        HStack {
                            Button("겹쳐 말하기 시작", systemImage: "person.2.wave.2") { controller.beginOverlapProbe() }
                            Button("겹쳐 말하기 종료", systemImage: "checkmark.circle") { controller.endOverlapProbe() }
                        }
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
