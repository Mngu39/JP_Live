import SwiftUI
import Translation

@MainActor
final class AppModel: ObservableObject {
    private struct DraftTranslationRequest {
        var id: UUID
        var captureID: UUID
        var source: String
        var language: SourceLanguage
        var eligibleAt: Double
    }

    @Published var language: SourceLanguage = .japanese
    @Published private var transcript = TranscriptBuffer()
    var captions: [Caption] {
        get { transcript.rows }
        set { transcript.rows = newValue }
    }
    @Published var status = "시스템 오디오를 시작하세요."
    @Published var running = false
    @Published var metrics = AudioMetrics()
    @Published var showRuby = false
    @Published var followLive = true
    @Published var translateConfiguration: TranslationSession.Configuration?
    @Published private(set) var translationPreparationFailed = false
    @Published private(set) var translationRevision = UUID()
    @Published private(set) var changingLanguage = false
    @Published var featureStatus = "분석 모델 준비 전 · 기본 STT"

    private var captureID = UUID()
    private var input: (any AudioInput)?
    private var runTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var speechTimeline = SpeechTimeline()
    private var speakerHints = SoftSpeakerMapper()
    private var audioThrough: Double?
    private let morphology = MorphologyWorker()
    private var morphologyTasks: [UUID: Task<Void, Never>] = [:]
    private var morphologyRequests: [UUID: UUID] = [:]
    private var morphologySources: [UUID: String] = [:]
    private var translationJobs = TranslationBacklog()
    private var draftTranslationRequest: DraftTranslationRequest?
    private var lastDraftTranslationStartedAt: Double = -Double.greatestFiniteMagnitude
    private var translatedDraftSources: [UUID: String] = [:]
    private let draftTranslationInterval: Double = 0.35
    var hasFailedTranslations: Bool { !translationJobs.failedIDs(language: language).isEmpty }
    private var languageChangeID = UUID()

    private var lastSession: LearningSession? {
        get { UserDefaults.standard.data(forKey: "lastSession").flatMap { try? JSONDecoder().decode(LearningSession.self, from: $0) } }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "lastSession") }
    }
    func selectedSession() -> LearningSession? { lastSession }
    func selectSession(_ value: LearningSession) { lastSession = value }
    func analyzeWords(_ source: String, language: SourceLanguage) async throws -> [WordToken] {
        try await morphology.tokens(source, language: language)
    }

    func learningScreenshot() async -> [String: Any]? {
        #if PHASE2
        return try? await SystemAudioInput.captureLearningScreenshot()
        #else
        return nil
        #endif
    }

    func retryFailedTranslations() {
        let ids = Set(translationJobs.retryFailed(language: language))
        guard !ids.isEmpty else { return }
        for index in captions.indices where ids.contains(captions[index].id) { captions[index].translationError = nil }
        configureTranslation()
    }

    func configureTranslation() {
        translationPreparationFailed = false
        translationRevision = UUID()
        let next: TranslationSession.Configuration
        #if PHASE2
        next = .init(source: .init(identifier: language.rawValue), target: .init(identifier: "ko"), preferredStrategy: .lowLatency)
        #else
        next = .init(source: .init(identifier: language.rawValue), target: .init(identifier: "ko"))
        #endif
        if translateConfiguration?.source == next.source && translateConfiguration?.target == next.target {
            translateConfiguration?.invalidate()
        } else { translateConfiguration = next }
        let pending = Set(translationJobs.pending(language: language))
        for index in captions.indices where pending.contains(captions[index].id) { captions[index].translationError = nil }
        queueDraftTranslation(language: language)
    }

    func setLanguage(_ next: SourceLanguage) async {
        let requestID = UUID(); languageChangeID = requestID
        guard next != language else { changingLanguage = false; return }
        changingLanguage = true
        await stop(returnToHome: false)
        guard requestID == languageChangeID else { return }
        draftTranslationRequest = nil; translatedDraftSources.removeAll(); lastDraftTranslationStartedAt = -Double.greatestFiniteMagnitude
        language = next; changingLanguage = false; configureTranslation()
    }

    func start(_ newInput: any AudioInput) async {
        guard !running && !changingLanguage else { return }
        if translationPreparationFailed { configureTranslation() }
        running = true; status = "음성 인식 준비 중…"; metrics = AudioMetrics()
        featureStatus = "기본 STT 먼저 시작 · 선택 모델 대기"
        captureID = UUID(); input = newInput
        let thisCapture = captureID
        let sourceLanguage = language
        transcript.begin(captureID: thisCapture, language: sourceLanguage)
        speechTimeline = SpeechTimeline(); speakerHints = SoftSpeakerMapper(); audioThrough = nil
        draftTranslationRequest = nil; translatedDraftSources.removeAll(); lastDraftTranslationStartedAt = -Double.greatestFiniteMagnitude
        // Required STT/input share one lifetime. Optional loading has a separate
        // per-capture mailbox, closed without waiting for downloads during stop.
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(newInput, capture: thisCapture, language: sourceLanguage)
        }
    }

    private func run(_ newInput: any AudioInput, capture: UUID, language: SourceLanguage) async {
        let pipeline = AudioPreprocessor(); let speech = AppleSpeechEngine()
        let optional = OptionalProviderPreparation()
        var optionalStarted = false
        var inputFailure: Error?
        do {
            try Task.checkCancellation()
            status = "Apple STT 준비 중…"
            try await speech.prepare(language: language, result: { [weak self] text, final, start, end in
                guard let self, self.captureID == capture else { return }
                let ready = self.transcript.receive(text, final: final, start: start, end: end,
                    speaker: self.speechTimeline.speaker(start: start, end: end), now: ProcessInfo.processInfo.systemUptime)
                self.enqueueTranslations(ready, language: language)
                self.queueDraftTranslation(language: language)
                self.scheduleMorphology(ready + [self.transcript.draftRowID].compactMap { $0 })
            }, failure: { [weak self] message in
                guard let self, self.captureID == capture else { return }
                self.status = "STT 오류: " + message
            })
            try Task.checkCancellation()
            let sequence = try await newInput.start()
            try Task.checkCancellation()
            status = "듣는 중"
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, self.captureID == capture else { return }
                    self.applyAnalysisUpdates(await pipeline.takeAnalysisUpdates())
                    let activityEnd = self.speechTimeline.latestEnd.map { min($0, self.audioThrough ?? $0) }
                    let activity = activityEnd.flatMap { self.speechTimeline.activity(through: $0) }
                    let ready = self.transcript.tick(now: ProcessInfo.processInfo.systemUptime, activity: activity)
                    self.enqueueTranslations(ready, language: language)
                    self.queueDraftTranslation(language: language)
                    self.scheduleMorphology(ready + [self.transcript.draftRowID].compactMap { $0 })
                }
            }
            for try await chunk in sequence {
                try Task.checkCancellation()
                let ready = await optional.takeReady()
                try Task.checkCancellation()
                await pipeline.installPrepared(analysis: ready.analysis, enhancement: ready.enhancement)
                try Task.checkCancellation()
                featureStatus = ready.status
                let (processed, value) = try await pipeline.process(chunk)
                metrics = value
                for output in processed { rememberAudio(output); try speech.append(output) }
                // Picker/input and the first basic STT buffer precede optional
                // downloads. Later completions are installed at the next boundary.
                if !optionalStarted && !processed.isEmpty {
                    try Task.checkCancellation()
                    optionalStarted = true
                    await optional.startAvailable()
                }
            }
        } catch {
            if !(error is CancellationError) { inputFailure = error; status = error.localizedDescription }
        }
        await optional.cancel()
        timerTask?.cancel(); timerTask = nil
        await newInput.stop()
        // Cleanup runs in a fresh task: cancelling the input loop must not also
        // cancel final conversion/STT finalization of already-accepted audio.
        let wasCancelled = Task.isCancelled
        let drainAcceptedAudio = inputFailure == nil
        let cleanup = Task { @MainActor () -> String? in
            do {
                if drainAcceptedAudio {
                    let tails = try await pipeline.finish(cancelAnalysis: wasCancelled)
                    self.applyAnalysisUpdates(await pipeline.takeAnalysisUpdates())
                    for tail in tails {
                        self.rememberAudio(tail); try speech.append(tail)
                    }
                    try await speech.finish()
                } else {
                    await pipeline.cancel()
                    try await speech.finish(aborting: true)
                }
                return nil
            } catch {
                let message = error.localizedDescription
                await pipeline.cancel()
                do { try await speech.finish(aborting: true) } catch { /* Keep the first failure. */ }
                return message
            }
        }
        let cleanupFailure = await cleanup.value
        if inputFailure == nil, let cleanupFailure { status = cleanupFailure }
        let ready = transcript.finish()
        enqueueTranslations(ready, language: language); queueDraftTranslation(language: language)
        scheduleMorphology(ready + captions.suffix(1).map(\.id))
        input = nil
        if Task.isCancelled && inputFailure == nil && cleanupFailure == nil { status = "입력 중지" }
        else if status == "듣는 중" { status = "입력 완료" }
        running = false
    }

    private func rememberAudio(_ output: PCMChunk) {
        let end = output.time + Double(output.buffer.frameLength)/output.buffer.format.sampleRate
        audioThrough = end
        if var decision = output.decision {
            decision.start = output.time; decision.end = end
            applyAnalysisUpdates([decision])
        }
    }

    private func applyAnalysisUpdates(_ decisions: [SpeechDecision]) {
        guard !decisions.isEmpty else { return }
        speechTimeline.append(decisions)
        let changed = transcript.applySpeakerTimeline(speechTimeline)
        for id in changed {
            guard let index = captions.firstIndex(where: { $0.id == id && $0.isFinal }) else { continue }
            let row = captions[index]
            captions[index].gutterHint = speakerHints.hint(slot: row.speaker, start: row.start, end: row.end)
        }
    }

    private func scheduleMorphology(_ ids: [UUID]) {
        for id in Array(morphologyTasks.keys) where !captions.contains(where: { $0.id == id }) {
            morphologyTasks.removeValue(forKey: id)?.cancel(); morphologyRequests[id] = nil; morphologySources[id] = nil
        }
        for id in Set(ids) {
            guard let row = captions.first(where: { $0.id == id }), row.tokens.isEmpty, !row.source.isEmpty else { continue }
            if morphologyTasks[id] != nil && morphologySources[id] == row.source { continue }
            morphologyTasks[id]?.cancel()
            let request = UUID(); morphologyRequests[id] = request; morphologySources[id] = row.source
            let worker = morphology
            morphologyTasks[id] = Task { [weak self] in
                do {
                    if !row.isFinal { try await Task.sleep(for: .milliseconds(150)) }
                    let tokens = try await worker.tokens(row.source, language: row.language)
                    try Task.checkCancellation()
                    guard let self, self.morphologyRequests[id] == request else { return }
                    if let index = self.captions.firstIndex(where: {
                        $0.id == id && $0.captureID == row.captureID && $0.source == row.source && $0.language == row.language
                    }) {
                        self.captions[index].tokens = tokens; self.captions[index].revision += 1
                    }
                    self.morphologyTasks[id] = nil; self.morphologyRequests[id] = nil; self.morphologySources[id] = nil
                } catch {
                    if let self, self.morphologyRequests[id] == request {
                        self.morphologyTasks[id] = nil; self.morphologyRequests[id] = nil; self.morphologySources[id] = nil
                    }
                }
            }
        }
    }

    func clearTranscript() {
        transcript.clearDisplay()
        for task in morphologyTasks.values { task.cancel() }
        morphologyTasks.removeAll(); morphologyRequests.removeAll(); morphologySources.removeAll()
        translationJobs = TranslationBacklog()
        draftTranslationRequest = nil; translatedDraftSources.removeAll()
        lastDraftTranslationStartedAt = -Double.greatestFiniteMagnitude
        followLive = true
    }

    func stop(returnToHome: Bool = false) async {
        if running, let task = runTask {
            status = "중지 중…"
            task.cancel()
            await input?.stop()
            await task.value
            if !running { runTask = nil }
        }
        if returnToHome {
            clearTranscript()
            metrics = AudioMetrics(); featureStatus = "분석 모델 준비 전 · 기본 STT"
            status = "시스템 오디오를 시작하세요."
        }
    }

    private func enqueueTranslations(_ ids: [UUID], language: SourceLanguage) {
        // Only final chunks provide distinct presentation evidence. Volatile changes
        // and multiple length-split rows with the same audio range cannot inflate it.
        for id in ids {
            guard let index = captions.firstIndex(where: { $0.id == id && $0.isFinal }) else { continue }
            let row = captions[index]
            captions[index].gutterHint = speakerHints.hint(slot: row.speaker, start: row.start, end: row.end)
        }
        translationJobs.enqueue(ids, language: language)
        if translationPreparationFailed && self.language == language {
            let pending = Set(ids)
            for index in captions.indices where pending.contains(captions[index].id) {
                captions[index].translationError = "번역 준비 실패 · 메뉴에서 다시 연결"
            }
        }
    }

    private func queueDraftTranslation(language: SourceLanguage) {
        guard language == self.language,
              let id = transcript.draftRowID,
              let row = captions.first(where: { $0.id == id && !$0.isFinal && $0.language == language }),
              ChunkBoundary.hasSemanticContent(row.source) else {
            draftTranslationRequest = nil
            return
        }
        if translatedDraftSources[id] == row.source { return }
        let now = ProcessInfo.processInfo.systemUptime
        let cadence = max(now, lastDraftTranslationStartedAt + draftTranslationInterval)
        if let existing = draftTranslationRequest, existing.id == id {
            draftTranslationRequest = DraftTranslationRequest(id: id, captureID: row.captureID, source: row.source,
                language: language, eligibleAt: min(existing.eligibleAt, cadence))
        } else {
            draftTranslationRequest = DraftTranslationRequest(id: id, captureID: row.captureID, source: row.source,
                language: language, eligibleAt: cadence)
        }
    }

    private func takeDraftTranslation(language: SourceLanguage, now: Double) -> DraftTranslationRequest? {
        guard let request = draftTranslationRequest, request.language == language, request.eligibleAt <= now else { return nil }
        draftTranslationRequest = nil; lastDraftTranslationStartedAt = now
        return request
    }

    func translationLoop(_ session: TranslationSession, language sessionLanguage: SourceLanguage, revision: UUID) async {
        guard sessionLanguage == language, revision == translationRevision, !Task.isCancelled else { return }
        do { try await session.prepareTranslation() }
        catch {
            if !Task.isCancelled && sessionLanguage == language && revision == translationRevision {
                translationPreparationFailed = true
                let pending = Set(translationJobs.pending(language: sessionLanguage))
                for index in captions.indices where pending.contains(captions[index].id) {
                    captions[index].translationError = "번역 준비 실패 · 메뉴에서 다시 연결"
                }
                status = "번역 준비 실패: " + error.localizedDescription
            }
            return
        }

        var servedDraftLast = false
        while !Task.isCancelled, sessionLanguage == language, revision == translationRevision {
            let now = ProcessInfo.processInfo.systemUptime
            if !servedDraftLast, let request = takeDraftTranslation(language: sessionLanguage, now: now) {
                do {
                    let response = try await session.translate(request.source)
                    if Task.isCancelled || revision != translationRevision { return }
                    // Latest-wins: a slow response for an older volatile hypothesis is discarded.
                    if let current = captions.firstIndex(where: {
                        $0.id == request.id && $0.captureID == request.captureID && !$0.isFinal && $0.source == request.source
                    }) {
                        captions[current].translation = response.targetText; captions[current].translationError = nil
                        captions[current].revision += 1
                        translatedDraftSources[request.id] = request.source
                    }
                } catch {
                    // Draft translation is opportunistic. Keep the last successful text on
                    // screen and let a later STT revision (or the final row) retry naturally.
                }
                servedDraftLast = true
                continue
            }

            if let id = translationJobs.take(language: sessionLanguage) {
                guard let row = captions.first(where: { $0.id == id && $0.isFinal && $0.language == sessionLanguage })
                else { translationJobs.complete(id); continue }
                do {
                    let response = try await session.translate(row.source)
                    if Task.isCancelled || revision != translationRevision { translationJobs.restore(id, language: sessionLanguage); return }
                    if let current = captions.firstIndex(where: { $0.id == id && $0.captureID == row.captureID && $0.source == row.source }) {
                        captions[current].translation = response.targetText; captions[current].translationError = nil
                        captions[current].revision += 1
                    }
                    translationJobs.complete(id)
                } catch {
                    if Task.isCancelled || revision != translationRevision { translationJobs.restore(id, language: sessionLanguage); return }
                    guard captions.contains(where: { $0.id == id }) else { translationJobs.complete(id); continue }
                    let retrying = translationJobs.failed(id, language: sessionLanguage, now: ProcessInfo.processInfo.systemUptime)
                    if let current = captions.firstIndex(where: { $0.id == id }) {
                        captions[current].translationError = retrying ? "번역 재시도 대기…" : "번역 실패 · 메뉴에서 실패한 번역 재시도"
                    }
                }
                servedDraftLast = false
                continue
            }

            if let request = takeDraftTranslation(language: sessionLanguage, now: ProcessInfo.processInfo.systemUptime) {
                do {
                    let response = try await session.translate(request.source)
                    if Task.isCancelled || revision != translationRevision { return }
                    if let current = captions.firstIndex(where: {
                        $0.id == request.id && $0.captureID == request.captureID && !$0.isFinal && $0.source == request.source
                    }) {
                        captions[current].translation = response.targetText; captions[current].translationError = nil
                        captions[current].revision += 1
                        translatedDraftSources[request.id] = request.source
                    }
                } catch { }
                servedDraftLast = true
                continue
            }

            servedDraftLast = false
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        }
    }
}
