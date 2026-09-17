import SwiftUI
import UniformTypeIdentifiers
import Translation

@main
struct JPLiveApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["JPLIVE_UNIT_TESTS"] == "1" {
                Color.clear // Hosted tests must not prepare Translation or contact services.
            } else { TranscriptView().environmentObject(model) }
        }
    }
}

struct PopupSelection: Identifiable {
    let id = UUID()
    let row: Caption
    let token: WordToken?
}

struct TranscriptView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importAudio = false
    @State private var settings = false
    @State private var logs = false
    @State private var selection: PopupSelection?
    var body: some View {
        let translationLanguage = model.language
        let translationRevision = model.translationRevision
        GeometryReader { geometry in
            let dock = geometry.size.width >= 620 && geometry.size.width > geometry.size.height * 1.35
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(model.running ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(model.status).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    if !model.captions.isEmpty {
                        Button { model.clearTranscript() } label: { Image(systemName: "trash") }
                            .accessibilityLabel("STT 내역 지우기")
                    }
                    if model.running {
                        Button { Task { await model.stop(returnToHome: true) } } label: { Image(systemName: "stop.fill") }
                            .accessibilityLabel("시스템 오디오 중지")
                    }
                    Menu {
                        #if PHASE2
                        if !model.running {
                            Button("시스템 오디오 시작", systemImage: "rectangle.inset.filled") {
                                Task { await model.start(SystemAudioInput()) }
                            }.disabled(model.changingLanguage)
                        }
                        #endif
                        Button("오디오 파일 열기", systemImage: "waveform") { importAudio = true }
                            .disabled(model.running || model.changingLanguage)
                        Divider()
                        ForEach(SourceLanguage.allCases) { language in
                            Button { Task { await model.setLanguage(language) } } label: {
                                if model.language == language { Label(language.title, systemImage: "checkmark") } else { Text(language.title) }
                            }.disabled(model.running || model.changingLanguage)
                        }
                        if model.language == .japanese {
                            Toggle("본문 후리가나", isOn: $model.showRuby)
                            Button("단어장", systemImage: "books.vertical") { logs = true }
                        }
                        Button("설정 · 연결 상태", systemImage: "gearshape") { settings = true }
                        if model.translationPreparationFailed {
                            Button("번역 다시 연결", systemImage: "arrow.clockwise") { model.configureTranslation() }
                        }
                        if model.hasFailedTranslations {
                            Button("실패한 번역 재시도", systemImage: "arrow.clockwise") { model.retryFailedTranslations() }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                }.padding(.horizontal, 12).frame(height: 42)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if model.captions.isEmpty {
                                VStack(spacing: 14) {
                                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                                    Text("원문과 한국어 번역을 함께 표시합니다.").font(.callout)
                                    HStack(spacing: 10) {
                                        #if PHASE2
                                        Button {
                                            Task { await model.start(SystemAudioInput()) }
                                        } label: {
                                            Label("시스템 오디오 시작", systemImage: "play.fill")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(model.running || model.changingLanguage)
                                        #else
                                        Button("오디오 파일 열기", systemImage: "waveform") { importAudio = true }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(model.running || model.changingLanguage)
                                        #endif
                                        Picker("언어", selection: Binding(
                                            get: { model.language },
                                            set: { next in Task { await model.setLanguage(next) } }
                                        )) {
                                            ForEach(SourceLanguage.allCases) { language in Text(language.code).tag(language) }
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 132)
                                        .disabled(model.running || model.changingLanguage)
                                    }
                                }.frame(maxWidth: .infinity).padding(.vertical, 44)
                            }
                            ForEach(model.captions) { row in
                                Group {
                                    if dock {
                                        HStack(alignment: .top, spacing: 18) {
                                            source(row).frame(maxWidth: .infinity, alignment: .leading)
                                            translation(row).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    } else {
                                        VStack(alignment: .leading, spacing: 7) { source(row); translation(row) }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.leading, 30).padding(.trailing, 14).padding(.vertical, 12)
                                .frame(minHeight: 44, alignment: .topLeading)
                                .overlay(alignment: .leading) {
                                    // The caption determines the overlay height. The full
                                    // 30-point gutter remains tappable on multiline rows.
                                    Button { selection = .init(row: row, token: nil) } label: {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(gutterColor(row.gutterHint).opacity(0.4))
                                            .frame(width: 3).padding(.vertical, 6)
                                            .frame(width: 30).frame(maxHeight: .infinity)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("문장 번역")
                                }.id(row.id)
                                Divider().padding(.leading, 30)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .simultaneousGesture(DragGesture().onChanged { _ in model.followLive = false })
                    .onChange(of: model.captions.count) { _, _ in if model.followLive { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: model.captions.last?.revision) { _, _ in if model.followLive { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .overlay(alignment: .bottomTrailing) {
                        if !model.followLive {
                            Button("실시간으로", systemImage: "arrow.down") {
                                model.followLive = true; proxy.scrollTo("bottom", anchor: .bottom)
                            }.buttonStyle(.borderedProminent).padding(12)
                        }
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .task { model.configureTranslation() }
        .translationTask(model.translateConfiguration) { session in
            await model.translationLoop(session, language: translationLanguage, revision: translationRevision)
        }
        .fileImporter(isPresented: $importAudio, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await model.start(FileAudioInput(url: url)) } }
            case .failure(let error): model.status = error.localizedDescription
            }
        }
        .sheet(item: $selection) { value in StudyPopup(selection: value).environmentObject(model) }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: $logs) { LogsScreen() }
    }
    private func source(_ row: Caption) -> some View {
        RubyText(text: row.source, tokens: row.tokens, ruby: row.language == .japanese && model.showRuby) {
            selection = .init(row: row, token: $0)
        }
    }
    private func gutterColor(_ hint: SpeakerGutterHint) -> Color {
        switch hint {
        case .neutral: return .secondary
        case .first: return .teal
        case .second: return .orange
        }
    }
    private func translation(_ row: Caption) -> some View {
        Text(row.translation.isEmpty ? (row.translationError ?? (row.isFinal ? "번역 중…" : "")) : row.translation)
            .font(.system(size: 18)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
