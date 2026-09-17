import SwiftUI

private struct DictionaryDestination: Identifiable {
    let id = UUID()
    let term: String
    let url: URL
}

struct StudyPopup: View {
    let selection: PopupSelection
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token: WordToken?
    @State private var baseTokens: [WordToken]
    @State private var lemmaReading = ""
    @State private var lemmaReadingKey = ""
    @State private var baseTranslation = ""
    @State private var reconstruction: WorkerClient.Reconstruction?
    @State private var useAI = false
    @State private var aiBusy = false
    @State private var busy = false
    @State private var meaning = ""
    @State private var error = ""
    @State private var saveStatus = ""
    @State private var choosingSession = false
    @State private var expandedKanji: String?
    @State private var dictionaryDestination: DictionaryDestination?
    init(selection: PopupSelection) {
        self.selection = selection
        _token = State(initialValue: selection.token)
        _baseTokens = State(initialValue: selection.row.tokens)
    }
    private var row: Caption { selection.row }
    private var tokens: [WordToken] { useAI ? reconstruction?.units ?? baseTokens : baseTokens }
    private var translation: String { useAI ? reconstruction?.translation ?? baseTranslation : baseTranslation }
    private var selectedKey: String { "\(token?.id ?? "sentence"):\(useAI)" }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let token {
                        let term = useAI ? token.surface : token.lemma
                        let reading = row.language == .japanese ? (useAI || token.lemma == token.surface ? token.reading : (lemmaReadingKey == selectedKey ? lemmaReading : "")) : ""
                        if row.language == .japanese {
                            Button { openDictionary(term) } label: {
                                RubyText(text: term, tokens: [.init(surface: term, lemma: term, reading: reading, start: 0, end: term.utf16.count)],
                                    ruby: true, size: 28) { _ in }
                            }.buttonStyle(.plain)
                        } else {
                            RubyText(text: term, tokens: [.init(surface: term, lemma: term, reading: "", start: 0, end: term.utf16.count)],
                                ruby: false, size: 28) { _ in }
                        }
                        if !useAI && token.surface != token.lemma { Text("표면형: \(token.surface)").foregroundStyle(.secondary) }
                        Text(meaning.isEmpty ? (error.isEmpty ? "뜻 불러오는 중…" : "뜻을 불러오지 못했습니다.") : meaning).font(.title3)
                        if useAI, let note = token.note, !note.isEmpty { Text(note).foregroundStyle(.secondary) }
                        if row.language == .japanese {
                            kanjiInfo(for: term)
                            if reading.isEmpty && LocalTokenizer.hasKanji(term) {
                                Text("현재 분석기에서 읽기를 확인하지 못했습니다.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        RubyText(text: row.source, tokens: tokens, ruby: row.language == .japanese, size: 23) { selected in
                            token = selected; error = ""; saveStatus = ""
                        }
                        if baseTokens.isEmpty { ProgressView("단어 분석 중…") }
                        Divider()
                        Text(translation.isEmpty ? (error.isEmpty ? "DeepL 번역 중…" : "번역을 불러오지 못했습니다.") : translation).font(.title3)
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.red).font(.callout) }
                    if !saveStatus.isEmpty { Text(saveStatus).foregroundStyle(.secondary).font(.callout) }
                    if row.language == .japanese {
                        if !row.isFinal { Text("인식 중인 자막 · 현재 표시된 내용을 저장합니다.").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("최근 세션에 저장", systemImage: "square.and.arrow.down") {
                                if let session = app.selectedSession() { Task { await save(session) } }
                                else { choosingSession = true }
                            }.buttonStyle(.borderedProminent).disabled(busy || baseTokens.isEmpty)
                            Button("세션 선택", systemImage: "plus") { choosingSession = true }.buttonStyle(.bordered).disabled(busy || baseTokens.isEmpty)
                        }
                    }
                }.padding(22)
            }
            .navigationTitle(token == nil ? "문장 번역" : "단어 번역")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if token != nil { Button("문장", systemImage: "chevron.left") { token = nil; error = ""; saveStatus = "" } }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if row.language == .japanese {
                        Button {
                            Task { await toggleAI() }
                        } label: {
                            if aiBusy { ProgressView() } else { Image(systemName: useAI ? "sparkles.square.filled.on.square" : "sparkles") }
                        }.accessibilityLabel(useAI ? "기본 분석으로 돌아가기" : "AI 재구성").disabled(aiBusy || busy || baseTokens.isEmpty)
                    }
                    Button("닫기") { dismiss() }
                }
            }
            .sheet(isPresented: $choosingSession) {
                SessionPicker { session in
                    app.selectSession(session)
                    choosingSession = false
                    Task { await save(session) }
                }
            }
            .sheet(item: $dictionaryDestination) { destination in
                DictionaryScreen(term: destination.term, url: destination.url)
            }
            .task {
                guard baseTokens.isEmpty else { return }
                do {
                    let value = try await app.analyzeWords(row.source, language: row.language)
                    if !Task.isCancelled { baseTokens = value }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .task(id: selectedKey + ":reading") {
                let key = selectedKey
                guard row.language == .japanese, !useAI, let selected = token, selected.lemma != selected.surface else { return }
                do {
                    let value = try await app.analyzeWords(selected.lemma, language: .japanese)
                    if !Task.isCancelled { lemmaReading = value.map(\.reading).joined(); lemmaReadingKey = key }
                } catch { if !Task.isCancelled { lemmaReading = ""; lemmaReadingKey = key } }
            }
            .task(id: selectedKey) {
                guard let selected = token else {
                    if baseTranslation.isEmpty {
                        do {
                            let value = try await WorkerClient.shared.translate(row.source, language: row.language)
                            if !Task.isCancelled { baseTranslation = value }
                        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    }
                    return
                }
                meaning = ""
                if useAI, let value = selected.meaning, !value.isEmpty { meaning = value; return }
                do {
                    let value = try await WorkerClient.shared.translate(selected.lemma, language: row.language)
                    if !Task.isCancelled { meaning = value }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
        .presentationDetents([.medium, .large])
    }
    @ViewBuilder private func kanjiInfo(for term: String) -> some View {
        let chars = term.map(String.init).filter { LocalTokenizer.hasKanji($0) }
        let unique = chars.enumerated().filter { index, ch in !chars.prefix(index).contains(ch) }.map(\.element)
        ForEach(unique, id: \.self) { ch in
            let deck = LearningData.deck[ch]
            let db = LearningData.kanji[ch]
            let gloss = deck?["mean"] ?? [db?["음"], db?["훈"]]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " · ")
            if let deck {
                DisclosureGroup(isExpanded: Binding(get: { expandedKanji == ch }, set: { expandedKanji = $0 ? ch : nil })) {
                    let unit = (deck["unit"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let explanation = deckExplanation(deck)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(explanation.isEmpty ? "(설명 없음)" : explanation)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !unit.isEmpty {
                            Text("#\(unit)").font(.caption2).fontWeight(.semibold)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                } label: { Text("\(ch) · \(gloss)") }
            } else {
                Button { openDictionary(ch) } label: {
                    Text(gloss.isEmpty ? ch : "\(ch) · \(gloss)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
    }
    private func openDictionary(_ term: String) {
        let query = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        guard let url = URL(string: "https://ja.dict.naver.com/#/search?range=all&query=\(query)") else { return }
        dictionaryDestination = DictionaryDestination(term: term, url: url)
    }
    private func deckExplanation(_ deck: [String: String]) -> String {
        var text = (deck["explain"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = (deck["unit"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "#" + unit
        if !unit.isEmpty, text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
    private func toggleAI() async {
        error = ""
        if reconstruction == nil {
            aiBusy = true; defer { aiBusy = false }
            do {
                if baseTranslation.isEmpty { baseTranslation = try await WorkerClient.shared.translate(row.source, language: row.language) }
                reconstruction = try await WorkerClient.shared.reconstruct(row, translation: baseTranslation, tokens: baseTokens)
            }
            catch { self.error = error.localizedDescription; return }
        }
        let old = token
        useAI.toggle()
        if let old { token = tokens.first { $0.start < old.end && $0.end > old.start } }
    }
    private func save(_ session: LearningSession) async {
        guard !busy, !baseTokens.isEmpty else { return }
        busy = true; error = ""; saveStatus = ""; defer { busy = false }
        let savedToken = token, savedTokens = tokens
        let screenshot = await app.learningScreenshot()
        var savedTranslation = translation
        do {
            if savedTranslation.isEmpty {
                savedTranslation = try await WorkerClient.shared.translate(row.source, language: row.language)
                baseTranslation = savedTranslation
            }
            let payload = try SavePayload.make(caption: row, session: session, token: savedToken, tokens: savedTokens,
                translation: savedTranslation, screenshot: screenshot)
            try await WorkerClient.shared.save(payload)
            app.selectSession(session)
            saveStatus = screenshot == nil
                ? "\(session.displayTitle)에 저장했습니다. · 스크린샷 캡처 실패"
                : "\(session.displayTitle)에 저장했습니다."
        } catch { self.error = "저장 확인 실패: \(error.localizedDescription)" }
    }
}

struct SessionPicker: View {
    var choose: (LearningSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var sessions: [LearningSession] = []
    @State private var error = ""
    @State private var busy = false
    @State private var resolveTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            List {
                Section("기존 세션 선택 또는 새 세션") {
                    TextField("세션명 또는 YouTube URL", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("이 이름·URL 사용") {
                        guard !busy else { return }
                        let requestedInput = input
                        busy = true
                        resolveTask = Task {
                            defer { busy = false }
                            do {
                                let session = try await WorkerClient.shared.resolve(requestedInput)
                                try Task.checkCancellation()
                                choose(session)
                            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        }
                    }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Section("기존 세션") {
                    ForEach(sessions) { session in Button(session.displayTitle) { choose(session) }.disabled(busy) }
                }
            }
            .navigationTitle("저장할 세션")
            .toolbar { Button("닫기") { dismiss() } }
            .onDisappear { resolveTask?.cancel(); resolveTask = nil }
            .task(id: input) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    let result = try await WorkerClient.shared.sessions(query: input)
                    if !Task.isCancelled { sessions = result; error = "" }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }
}
