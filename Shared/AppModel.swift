import SwiftUI
import Translation

@MainActor
final class AppModel: ObservableObject {
    // Internal so EOF/debounce ordering can be tested without an Apple recognizer.
    struct BufferedSpeechResult {
        var text: String
        var final: Bool
        var start: Double
        var end: Double
        var finalizedThrough: Double? = nil
    }

    private struct DraftTranslationRequest {
        var id: UUID
        var captureID: UUID
        var source: String
        var language: SourceLanguage
        var eligibleAt: Double
    }

    @Published var language: SourceLanguage = .japanese
    @Published private var transcript = TranscriptBuffer()
    private var revisionTranscript = TranscriptBuffer()
    var captions: [Caption] { transcript.rows }
    private var captionIndices: [UUID: Int] = [:]
    @Published var status = "시스템 오디오를 시작하세요."
    @Published var running = false
    @Published var metrics = AudioMetrics()
    @Published private(set) var liveDiagnostics = LivePipelineDiagnostics()
    @Published private(set) var separationDiagnostics = SeparationDiagnostics()
    private var separation: LiveSeparationPass?
    @Published var showRuby = false
    @Published private(set) var splitMode = SudachiSplitMode.stored()
    @Published private(set) var morphologyStatus = LocalTokenizer.engineName
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
    private var retokenizationTask: Task<Void, Never>?
    private var morphologyTasks: [UUID: Task<Void, Never>] = [:]
    private var morphologyRequests: [UUID: UUID] = [:]
    private var morphologySources: [UUID: String] = [:]
    private var translationJobs = TranslationBacklog()
    private var draftTranslationRequest: DraftTranslationRequest?
    private var lastDraftTranslationStartedAt: Double = -Double.greatestFiniteMagnitude
    private var translatedDraftSources: [UUID: String] = [:]
    private let draftTranslationInterval: Double = 0.35
    private let primaryVolatileDebounce: Double = 0.15
    private let speechSourceTimeTolerance: Double = 1.0 / 48000
    private var bufferedPrimaryVolatile: BufferedSpeechResult?
    private var primaryVolatileTask: Task<Void, Never>?
    private(set) var qualityRevisionCount = 0
    private var consumedQualityRevisionIDs: Set<UUID> = []
    var hasFailedTranslations: Bool { !translationJobs.failedIDs(language: language).isEmpty }
    private var languageChangeID = UUID()

    private var lastSession: LearningSession? {
        get { UserDefaults.standard.data(forKey: "lastSession").flatMap { try? JSONDecoder().decode(LearningSession.self, from: $0) } }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "lastSession") }
    }
    func selectedSession() -> LearningSession? { lastSession }
    func selectSession(_ value: LearningSession) { lastSession = value }
    func analyzeWords(_ source: String, language: SourceLanguage) async throws -> [WordToken] {
        let mode = language == .japanese ? splitMode : .c
        let result = try await morphology.analyze(source, language: language, mode: mode)
        try Task.checkCancellation()
        guard language != .japanese || mode == splitMode else { throw CancellationError() }
        if language == .japanese { morphologyStatus = result.warning ?? result.engine }
        return result.tokens
    }

    func setSplitMode(_ mode: SudachiSplitMode) {
        guard mode != splitMode else { return }
        splitMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: SudachiSplitMode.preferenceKey)
        retokenizationTask?.cancel()
        let rows = captions.filter { $0.language == .japanese }
        for row in rows {
            morphologyTasks.removeValue(forKey: row.id)?.cancel()
            morphologyRequests[row.id] = nil; morphologySources[row.id] = nil
        }
        for index in captions.indices where transcript.rows[index].language == .japanese {
            transcript.rows[index].tokens = []; transcript.rows[index].revision += 1
        }
        // One cancellable background walk, newest first. Never spawn one task per
        // historical caption or put history work ahead of every live STT update.
        retokenizationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            for row in rows.reversed() {
                do {
                    try Task.checkCancellation()
                    let tokens = try await self.analyzeWords(row.source, language: .japanese)
                    guard self.splitMode == mode else { return }
                    if let index = self.captionIndex(row.id, matching: { $0.id == row.id && $0.captureID == row.captureID && $0.source == row.source
                    }) {
                        self.transcript.rows[index].tokens = tokens; self.transcript.rows[index].revision += 1
                    }
                    await Task.yield()
                } catch { if Task.isCancelled { return } }
            }
        }
    }

    func learningScreenshot() async -> [String: Any]? {
        #if PHASE2
        guard let systemInput = input as? SystemAudioInput else { return nil }
        return try? await systemInput.captureLearningScreenshot()
        #else
        return nil
        #endif
    }

    func retryFailedTranslations() {
        let ids = Set(translationJobs.retryFailed(language: language))
        guard !ids.isEmpty else { return }
        for index in captions.indices where ids.contains(transcript.rows[index].id) { transcript.rows[index].translationError = nil }
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
        for index in captions.indices where pending.contains(transcript.rows[index].id) { transcript.rows[index].translationError = nil }
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
        liveDiagnostics = LivePipelineDiagnostics()
        featureStatus = "기본 STT 먼저 시작 · 선택 모델 대기"
        captureID = UUID(); input = newInput
        let thisCapture = captureID
        let sourceLanguage = language
        transcript.begin(captureID: thisCapture, language: sourceLanguage)
        revisionTranscript.begin(captureID: thisCapture, language: sourceLanguage)
        primaryVolatileTask?.cancel(); primaryVolatileTask = nil; bufferedPrimaryVolatile = nil
        qualityRevisionCount = 0
        consumedQualityRevisionIDs.removeAll(keepingCapacity: true)
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
        let startedAt = ProcessInfo.processInfo.systemUptime
        let pipeline = AudioPreprocessor()
        let revisionPipeline = AudioPreprocessor(analysisPolicy: .qualityRevision)
        let speech = AppleSpeechEngine()
        #if PHASE2
        separation = LiveSeparationPass { [weak self] original, rows in
            guard let self, self.captureID == capture else { return false }
            let ids = self.transcript.applySeparation(original: original, separated: rows)
            guard !ids.isEmpty else { return false }
            self.translationJobs.invalidate([original.id])
            self.translatedDraftSources[original.id] = nil
            self.morphologyTasks.removeValue(forKey: original.id)?.cancel()
            self.morphologyRequests[original.id] = nil; self.morphologySources[original.id] = nil
            self.captionIndices.removeAll(keepingCapacity: true)
            self.enqueueTranslations(ids, language: language); self.scheduleMorphology(ids)
            return true
        }
        separationDiagnostics = separation?.diagnostics ?? SeparationDiagnostics()
        #endif
        let quality = QualitySpeechPass(pipeline: revisionPipeline, language: language,
            result: { [weak self] text, final, start, end, finalizedThrough in
                guard let self, self.captureID == capture else { return }
                let ready = self.revisionTranscript.receive(text, final: final, start: start, end: end,
                    speaker: self.speechTimeline.speaker(start: start, end: end),
                    now: ProcessInfo.processInfo.systemUptime, finalizedThrough: finalizedThrough)
                self.applyQualityRevisions(ready, language: language)
            }, output: { [weak self] chunk in
                guard let self, self.captureID == capture else { return }
                self.rememberRevisionAudio(chunk)
            }, status: { [weak self] message in
                guard let self, self.captureID == capture else { return }
                if self.featureStatus != message { self.featureStatus = message }
            })
        var inputFailure: Error?
        do {
            try Task.checkCancellation()
            status = "Apple STT 준비 중…"
            try await speech.prepare(language: language, result: { [weak self] text, final, start, end, finalizedThrough in
                guard let self, self.captureID == capture else { return }
                self.receivePrimarySpeech(.init(text: text, final: final, start: start, end: end,
                    finalizedThrough: finalizedThrough), language: language)
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
                    let inputProgress = newInput.progress?.snapshot() ?? AudioInputSnapshot()
                    quality.observeFastBacklog(inputProgress.pendingAudio)
                    self.liveDiagnostics = LivePipelineDiagnostics(input: inputProgress, quality: quality.diagnostics,
                        qualityRevisions: self.qualityRevisionCount, captionCount: self.captions.count,
                        elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
                    let analysisUpdates = await revisionPipeline.takeAnalysisUpdates()
                    guard !Task.isCancelled, self.captureID == capture else { return }
                    self.applyAnalysisUpdates(analysisUpdates)
                    let activityEnd = self.speechTimeline.latestEnd.map { min($0, self.audioThrough ?? $0) }
                    let activity = activityEnd.flatMap { self.speechTimeline.activity(through: $0) }
                    let now = ProcessInfo.processInfo.systemUptime
                    let ready = self.transcript.tick(now: now, activity: activity)
                    self.enqueueTranslations(ready, language: language)
                    self.queueDraftTranslation(language: language)
                    self.scheduleMorphology(ready + [self.transcript.draftRowID].compactMap { $0 })
                    let revisionReady = self.revisionTranscript.tick(now: now, activity: activity)
                    self.applyQualityRevisions(revisionReady, language: language)
                    self.separation?.consider(Array(self.captions.suffix(32).filter { $0.captureID == capture }),
                        timeline: self.speechTimeline, fastBacklog: inputProgress.pendingAudio)
                    if let separation = self.separation { self.separationDiagnostics = separation.diagnostics }
                }
            }
            for try await chunk in sequence {
                try Task.checkCancellation()
                let (processed, value) = try await pipeline.process(chunk)
                metrics = value
                for output in processed { rememberAudio(output); try speech.append(output) }
                newInput.progress?.processed(chunk)
                // Synchronous bounded enqueue only. Model preparation, enhancement,
                // second STT and their failures never suspend this fast input loop.
                #if PHASE2
                if quality.hasStarted || !processed.isEmpty { quality.offer(chunk) }
                #endif
            }
        } catch {
            if !(error is CancellationError) { inputFailure = error; status = error.localizedDescription }
        }
        timerTask?.cancel(); timerTask = nil
        // Manual stop/error cancels optional work immediately. Natural EOF
        // keeps its PCM window until the final STT and analysis rows arrive.
        if Task.isCancelled || inputFailure != nil { separation?.stop() }
        await newInput.stop()
        // Cleanup runs in a fresh task: cancelling the input loop must not also
        // cancel final conversion/STT finalization of already-accepted audio.
        let wasCancelled = Task.isCancelled
        // User Stop intentionally discards the screen/history immediately afterward.
        // Do not make it wait for accepted primary PCM or any optional correction pass.
        // Natural EOF still drains accepted audio so file/stream completion can finalize text.
        let drainAcceptedAudio = inputFailure == nil && !wasCancelled
        if wasCancelled || inputFailure != nil { await quality.finish(aborting: true) }
        let cleanup = Task { @MainActor () -> String? in
            do {
                if drainAcceptedAudio {
                    let tails = try await pipeline.finish(cancelAnalysis: wasCancelled)
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
        await quality.finish(aborting: wasCancelled || inputFailure != nil || cleanupFailure != nil)
        if !wasCancelled {
            applyAnalysisUpdates(await revisionPipeline.takeAnalysisUpdates())
            let revisionReady = revisionTranscript.finish()
            applyQualityRevisions(revisionReady, language: language)
        }
        if inputFailure == nil, let cleanupFailure { status = cleanupFailure }
        let ready = finishPrimaryTranscript(language: language)
        enqueueTranslations(ready, language: language); queueDraftTranslation(language: language)
        if !wasCancelled {
            for revised in revisionTranscript.rows.suffix(8) where revised.isFinal {
                applyQualityCaption(revised, language: language)
            }
        }
        scheduleMorphology(ready + captions.suffix(1).map(\.id))
        if let separation {
            if !Task.isCancelled && inputFailure == nil && cleanupFailure == nil {
                await separation.finish(rows: Array(captions.suffix(32).filter { $0.captureID == capture }),
                                        timeline: speechTimeline)
            } else {
                separation.stop()
            }
            separationDiagnostics = separation.diagnostics
        }
        separation = nil
        input = nil
        if Task.isCancelled && inputFailure == nil && cleanupFailure == nil { status = "입력 중지" }
        else if status == "듣는 중" { status = "입력 완료" }
        running = false
        liveDiagnostics = LivePipelineDiagnostics(input: newInput.progress?.snapshot() ?? AudioInputSnapshot(),
            quality: quality.diagnostics, qualityRevisions: qualityRevisionCount, captionCount: captions.count,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
    }

    func finishPrimaryTranscript(language: SourceLanguage) -> [UUID] {
        primaryVolatileTask?.cancel(); primaryVolatileTask = nil
        let latest = bufferedPrimaryVolatile; bufferedPrimaryVolatile = nil
        // EOF may beat the 150 ms UI debounce. Preserve the latest tentative
        // result before finish marks it unconfirmed; Clear/final already revoke it.
        if let latest { applyPrimarySpeech(latest, language: language) }
        return transcript.finish()
    }

    func receivePrimarySpeech(_ result: BufferedSpeechResult, language: SourceLanguage) {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // The 150 ms UI debounce must never erase a previous phrase that Apple has
        // already finalized only through resultsFinalizationTime. If a newer, disjoint
        // callback advances the frontier past the buffered phrase, feed that phrase to
        // TranscriptBuffer before replacing the one-slot visual debounce buffer. The
        // incoming callback will then let TranscriptBuffer promote it by source time.
        flushBufferedPrimaryIfFinalized(by: result, language: language)

        if result.final {
            primaryVolatileTask?.cancel(); primaryVolatileTask = nil; bufferedPrimaryVolatile = nil
            applyPrimarySpeech(result, language: language)
            return
        }
        if trimmed.isEmpty {
            // Empty volatile results are semantic revocations in SpeechTranscriber, not
            // merely another visual draft. Apply them immediately so the 150 ms display
            // debounce cannot lose a revocation when a later callback arrives. Cancel a
            // buffered visual hypothesis only when this revocation targets that same range.
            if let buffered = bufferedPrimaryVolatile {
                let sameStart = abs(buffered.start-result.start) <= speechSourceTimeTolerance
                let overlaps = result.start < buffered.end && result.end > buffered.start
                if sameStart || overlaps {
                    primaryVolatileTask?.cancel(); primaryVolatileTask = nil; bufferedPrimaryVolatile = nil
                }
            }
            applyPrimarySpeech(result, language: language)
            return
        }
        bufferedPrimaryVolatile = result
        guard primaryVolatileTask == nil else { return }
        let debounceMilliseconds = Int(primaryVolatileDebounce * 1000)
        primaryVolatileTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(debounceMilliseconds)) } catch { return }
            guard let self else { return }
            let latest = self.bufferedPrimaryVolatile
            self.bufferedPrimaryVolatile = nil
            self.primaryVolatileTask = nil
            if let latest { self.applyPrimarySpeech(latest, language: language) }
        }
    }

    private func flushBufferedPrimaryIfFinalized(by incoming: BufferedSpeechResult, language: SourceLanguage) {
        guard let buffered = bufferedPrimaryVolatile,
              let frontier = incoming.finalizedThrough, frontier.isFinite,
              buffered.end <= frontier + speechSourceTimeTolerance else { return }
        let sameStart = abs(buffered.start-incoming.start) <= speechSourceTimeTolerance
        let overlaps = incoming.start < buffered.end && incoming.end > buffered.start
        guard !sameStart && !overlaps else { return }
        primaryVolatileTask?.cancel(); primaryVolatileTask = nil; bufferedPrimaryVolatile = nil
        applyPrimarySpeech(buffered, language: language)
    }

    private func applyPrimarySpeech(_ result: BufferedSpeechResult, language: SourceLanguage) {
        let ready = transcript.receive(result.text, final: result.final, start: result.start, end: result.end,
            speaker: speechTimeline.speaker(start: result.start, end: result.end),
            now: ProcessInfo.processInfo.systemUptime, finalizedThrough: result.finalizedThrough)
        enqueueTranslations(ready, language: language)
        queueDraftTranslation(language: language)
        scheduleMorphology(ready + [transcript.draftRowID].compactMap { $0 })
        if !ready.isEmpty {
            // A quality sentence can arrive before the fast path has sealed its row.
            // Retry only the recent hidden finals when a new visible sentence appears.
            for revised in revisionTranscript.rows.suffix(8) where revised.isFinal {
                applyQualityCaption(revised, language: language)
            }
        }
    }

    private func applyQualityRevisions(_ ids: [UUID], language: SourceLanguage) {
        for id in ids {
            guard let revised = revisionTranscript.rows.first(where: { $0.id == id && $0.isFinal }) else { continue }
            applyQualityCaption(revised, language: language)
        }
        if revisionTranscript.rows.count > 32 {
            let excess = revisionTranscript.rows.count - 32
            let removed = revisionTranscript.rows.prefix(excess).map(\.id)
            revisionTranscript.rows.removeFirst(excess)
            consumedQualityRevisionIDs.subtract(removed)
        }
    }

    private func applyQualityCaption(_ revised: Caption, language: SourceLanguage) {
        guard !consumedQualityRevisionIDs.contains(revised.id) else { return }
        switch transcript.resolveRevision(revised) {
        case .pending:
            // The fast path has not sealed the exact source interval yet. Retry once a
            // newer primary final arrives, but never replay a revision after it was decided.
            return
        case .rejected:
            consumedQualityRevisionIDs.insert(revised.id)
            return
        case .applied(let effect):
            consumedQualityRevisionIDs.insert(revised.id)
            qualityRevisionCount += 1
            let invalid = [effect.updatedID] + effect.removedIDs
            translationJobs.invalidate(invalid)
            translatedDraftSources[effect.updatedID] = nil
            for removed in effect.removedIDs {
                translatedDraftSources[removed] = nil
                morphologyTasks.removeValue(forKey: removed)?.cancel()
                morphologyRequests[removed] = nil; morphologySources[removed] = nil
            }
            enqueueTranslations([effect.updatedID], language: language)
            scheduleMorphology([effect.updatedID])
        }
    }

    private func rememberRevisionAudio(_ output: PCMChunk) {
        let end = output.time + Double(output.buffer.frameLength)/output.buffer.format.sampleRate
        if var decision = output.decision {
            decision.start = output.time; decision.end = end
            applyAnalysisUpdates([decision])
        }
    }

    private func rememberAudio(_ output: PCMChunk) {
        separation?.offer(output)
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
            guard let index = captionIndex(id, matching: { $0.id == id && $0.isFinal }) else { continue }
            let row = transcript.rows[index]
            transcript.rows[index].gutterHint = speakerHints.hint(for: row)
        }
    }

    private func scheduleMorphology(_ ids: [UUID]) {
        for id in Array(morphologyTasks.keys) where !(captionIndex(id, matching: { $0.id == id }) != nil) {
            morphologyTasks.removeValue(forKey: id)?.cancel(); morphologyRequests[id] = nil; morphologySources[id] = nil
        }
        for id in Set(ids) {
            guard let row = caption(id, matching: { $0.id == id }), row.tokens.isEmpty, !row.source.isEmpty else { continue }
            if morphologyTasks[id] != nil && morphologySources[id] == row.source { continue }
            morphologyTasks[id]?.cancel()
            let request = UUID(); morphologyRequests[id] = request; morphologySources[id] = row.source
            let worker = morphology
            let mode = row.language == .japanese ? splitMode : .c
            morphologyTasks[id] = Task { [weak self] in
                do {
                    if !row.isFinal { try await Task.sleep(for: .milliseconds(150)) }
                    let analysis = try await worker.analyze(row.source, language: row.language, mode: mode)
                    try Task.checkCancellation()
                    guard let self, self.morphologyRequests[id] == request else { return }
                    guard row.language != .japanese || self.splitMode == mode else { return }
                    if let index = self.captionIndex(id, matching: { $0.id == id && $0.captureID == row.captureID && $0.source == row.source && $0.language == row.language
                    }) {
                        self.transcript.rows[index].tokens = analysis.tokens; self.transcript.rows[index].revision += 1
                        if row.language == .japanese { self.morphologyStatus = analysis.warning ?? analysis.engine }
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

    // Clear is a presentation boundary, not an input restart. Audio already captured before
    // the tap may still be waiting in the required fast queue, so the watermark must cover
    // the capture frontier as well as PCM already processed by this model. Otherwise queued
    // pre-Clear speech can arrive later and repopulate the empty transcript.
    static func clearWatermark(processedThrough: Double?, capturedThrough: Double?) -> Double? {
        [processedThrough, capturedThrough].compactMap { $0 }.filter { $0.isFinite }.max()
    }

    func clearTranscript() {
        separation?.clear()
        captionIndices.removeAll(keepingCapacity: true)
        retokenizationTask?.cancel(); retokenizationTask = nil
        let capturedThrough = input?.progress?.snapshot().capturedThrough
        let clearThrough = Self.clearWatermark(processedThrough: audioThrough, capturedThrough: capturedThrough)
        transcript.clearDisplay(through: clearThrough)
        revisionTranscript.clearDisplay(through: clearThrough)
        consumedQualityRevisionIDs.removeAll(keepingCapacity: true)
        primaryVolatileTask?.cancel(); primaryVolatileTask = nil; bufferedPrimaryVolatile = nil
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
            // Invalidate all recognizer/model callbacks before teardown begins. A late
            // callback from the cancelled capture must never repopulate the transcript
            // or race the next Start/language selection.
            captureID = UUID()
            separation?.stop()
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
            guard let index = captionIndex(id, matching: { $0.id == id && $0.isFinal }) else { continue }
            let row = transcript.rows[index]
            transcript.rows[index].gutterHint = speakerHints.hint(for: row)
        }
        translationJobs.enqueue(ids, language: language)
        if translationPreparationFailed && self.language == language {
            let pending = Set(ids)
            for index in captions.indices where pending.contains(transcript.rows[index].id) {
                transcript.rows[index].translationError = "번역 준비 실패 · 메뉴에서 다시 연결"
            }
        }
    }

    private func queueDraftTranslation(language: SourceLanguage) {
        guard language == self.language,
              let id = transcript.draftRowID,
              let row = caption(id, matching: { $0.id == id && !$0.isFinal && $0.language == language }),
              SentenceBoundary.hasSemanticContent(row.source) else {
            draftTranslationRequest = nil
            translatedDraftSources.removeAll(keepingCapacity: true)
            return
        }
        // Only the current draft needs a deduplication key. Finalized/revoked
        // draft texts must not accumulate for the entire live capture.
        translatedDraftSources = translatedDraftSources.filter { $0.key == id }
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
                for index in captions.indices where pending.contains(transcript.rows[index].id) {
                    transcript.rows[index].translationError = "번역 준비 실패 · 메뉴에서 다시 연결"
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
                    if let current = captionIndex(request.id, matching: { $0.id == request.id && $0.captureID == request.captureID && !$0.isFinal && $0.source == request.source
                    }) {
                        transcript.rows[current].translation = response.targetText; transcript.rows[current].translationError = nil
                        transcript.rows[current].revision += 1
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
                guard let row = caption(id, matching: { $0.id == id && $0.isFinal && $0.language == sessionLanguage })
                else { translationJobs.complete(id); continue }
                do {
                    let response = try await session.translate(row.source)
                    if Task.isCancelled || revision != translationRevision {
                        if currentTranslationRow(row) != nil { translationJobs.restore(id, language: sessionLanguage) }
                        return
                    }
                    if let current = currentTranslationRow(row) {
                        transcript.rows[current].translation = response.targetText; transcript.rows[current].translationError = nil
                        transcript.rows[current].revision += 1
                        translationJobs.complete(id)
                    }
                } catch {
                    if Task.isCancelled || revision != translationRevision {
                        if currentTranslationRow(row) != nil { translationJobs.restore(id, language: sessionLanguage) }
                        return
                    }
                    // Quality correction/Clear already invalidated the old job. Its
                    // late failure must not change retries or errors of the new source.
                    guard let current = currentTranslationRow(row) else { continue }
                    let retrying = translationJobs.failed(id, language: sessionLanguage, now: ProcessInfo.processInfo.systemUptime)
                    transcript.rows[current].translationError = retrying ? "번역 재시도 대기…" : "번역 실패 · 메뉴에서 실패한 번역 재시도"
                }
                servedDraftLast = false
                continue
            }

            if let request = takeDraftTranslation(language: sessionLanguage, now: ProcessInfo.processInfo.systemUptime) {
                do {
                    let response = try await session.translate(request.source)
                    if Task.isCancelled || revision != translationRevision { return }
                    if let current = captionIndex(request.id, matching: { $0.id == request.id && $0.captureID == request.captureID && !$0.isFinal && $0.source == request.source
                    }) {
                        transcript.rows[current].translation = response.targetText; transcript.rows[current].translationError = nil
                        transcript.rows[current].revision += 1
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

    // Corrections can merge rows and shift indices. Validate cached identity before
    // using it; on a miss search newest first. This bounds the lookup cache without
    // deleting any transcript history or copying the array through a computed setter.
    private func captionIndex(_ id: UUID, matching predicate: (Caption) -> Bool = { _ in true }) -> Int? {
        let index: Int
        if let cached = captionIndices[id], transcript.rows.indices.contains(cached), transcript.rows[cached].id == id {
            index = cached
        } else {
            guard let found = transcript.rows.lastIndex(where: { $0.id == id }) else {
                captionIndices[id] = nil; return nil
            }
            if captionIndices.count >= 2048 { captionIndices.removeAll(keepingCapacity: true) }
            captionIndices[id] = found; index = found
        }
        return predicate(transcript.rows[index]) ? index : nil
    }
    private func caption(_ id: UUID, matching predicate: (Caption) -> Bool = { _ in true }) -> Caption? {
        guard let index = captionIndex(id, matching: predicate) else { return nil }
        return transcript.rows[index]
    }

    private func currentTranslationRow(_ request: Caption) -> Int? {
        captionIndex(request.id) {
            $0.id == request.id && $0.captureID == request.captureID &&
            $0.isFinal && $0.language == request.language && $0.source == request.source
        }
    }
}

// MainActor owns delivery state; costly PCM/model work runs on its provider actors.
// No async method on this object is called from the required input loop.
@MainActor
enum QualityWorkLease {
    private static var owner: UUID?
    static func acquire(_ id: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = id; return true
    }
    static func release(_ id: UUID) { if owner == id { owner = nil } }
}

@MainActor
final class QualitySpeechPass {
    private let pipeline: AudioPreprocessor
    private let language: SourceLanguage
    private let result: (String, Bool, Double, Double, Double?) -> Void
    private let output: (PCMChunk) -> Void
    private let status: (String) -> Void
    private let speech: any QualitySpeechSink
    private let optional: OptionalProviderPreparation
    private var continuation: AsyncStream<PCMChunk>.Continuation?
    private var task: Task<Void, Never>?
    private var accepting = false
    private var closed = false
    private var budget = QualityAudioBudget()
    private var observations = QualityPassDiagnostics()
    private var pressureSince: Double?
    private var consumerFinished = true
    private let finishTimeout: TimeInterval
    var diagnostics: QualityPassDiagnostics {
        var value = observations; value.backlog = budget.duration; return value
    }
    private(set) var hasStarted = false
    var acceptingInput: Bool { accepting && !closed }

    init(pipeline: AudioPreprocessor, language: SourceLanguage,
         speech: (any QualitySpeechSink)? = nil,
         optional: OptionalProviderPreparation = OptionalProviderPreparation(),
         finishTimeout: TimeInterval = 8,
         result: @escaping (String, Bool, Double, Double, Double?) -> Void,
         output: @escaping (PCMChunk) -> Void, status: @escaping (String) -> Void) {
        self.pipeline = pipeline; self.language = language
        self.speech = speech ?? AppleSpeechEngine(); self.optional = optional
        self.finishTimeout = finishTimeout.isFinite && finishTimeout > 0 ? finishTimeout : 8
        self.result = result; self.output = output; self.status = status
    }

    func offer(_ chunk: PCMChunk) {
        guard !closed else { observations.skippedChunks += 1; return }
        if !hasStarted {
            hasStarted = true
            let lease = UUID()
            guard QualityWorkLease.acquire(lease) else {
                observations.skippedChunks += 1
                disable("이전 보정 작업 정리 중 · 이번 실행은 빠른 STT 유지")
                return
            }
            let (stream, input) = AsyncStream<PCMChunk>.makeStream(bufferingPolicy: .bufferingOldest(256))
            continuation = input
            consumerFinished = false
            task = Task(priority: .utility) {
                defer { QualityWorkLease.release(lease); consumerFinished = true }
                await consume(stream)
            }
        }
        // Preparation is optional: never buffer an entire model download.
        guard accepting, let continuation else { observations.skippedChunks += 1; return }
        let duration = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
        guard budget.reserve(duration: duration) else {
            observations.skippedChunks += 1; observations.overloadStops += 1
            disable("보정 처리 지연 · 빠른 STT 유지")
            return
        }
        observations.peakBacklog = max(observations.peakBacklog, budget.duration)
        observations.acceptedThrough = chunk.time + duration
        switch continuation.yield(chunk) {
        case .enqueued: break
        case .dropped, .terminated: disable("보정 입력 종료 · 빠른 STT 유지")
        @unknown default: disable("보정 입력 상태 오류 · 빠른 STT 유지")
        }
    }

    private func disable(_ message: String) {
        guard !closed else { return }
        closed = true; accepting = false
        observations.stoppedReason = message
        continuation?.finish(); continuation = nil; task?.cancel()
        Task { await optional.cancel() }
        status(message)
    }

    func observeFastBacklog(_ duration: Double) {
        guard hasStarted, !closed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if duration < 0.75 { pressureSince = nil; return }
        if pressureSince == nil { pressureSince = now }
        if now - (pressureSince ?? now) >= 1 {
            observations.overloadStops += 1
            disable("빠른 STT 지연 증가 · 이번 실행의 보정 처리 중단")
        }
    }

    private func consume(_ stream: AsyncStream<PCMChunk>) async {
        var pipelineStarted = false
        do {
            await optional.startAvailable()
            try Task.checkCancellation()
            try await speech.prepareForQuality(language: language, result: { [weak self] text, final, start, end, finalizedThrough in
                guard let self, !self.closed else { return }
                self.observations.recognitionThrough = max(self.observations.recognitionThrough ?? end, end)
                self.result(text, final, start, end, finalizedThrough)
            }, failure: { [weak self] message in
                self?.disable("보정 STT 오류 · 빠른 STT 유지: " + message)
            })
            try Task.checkCancellation()
            accepting = true
            for await chunk in stream {
                try Task.checkCancellation()
                let ready = await optional.takeReady()
                try Task.checkCancellation()
                if ready.analysis != nil || ready.enhancement != nil {
                    await pipeline.installPrepared(analysis: ready.analysis, enhancement: ready.enhancement)
                    if ready.analysis != nil {
                        pipelineStarted = true; observations.analysisActivatedAt = chunk.time
                    }
                    if ready.enhancement != nil { observations.enhancementActivatedAt = chunk.time }
                }
                try Task.checkCancellation()
                status(ready.status)
                if pipelineStarted {
                    let (chunks, _) = try await pipeline.process(chunk)
                    try Task.checkCancellation()
                    for value in chunks { try deliver(value) }
                } else {
                    observations.skippedChunks += 1
                }
                budget.release(duration: Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate)
            }
            try Task.checkCancellation()
            if pipelineStarted {
                let tails = try await pipeline.finish()
                for value in tails {
                    try Task.checkCancellation()
                    try deliver(value)
                }
                try await speech.finish(aborting: false)
            } else {
                try await speech.finish(aborting: true)
            }
        } catch {
            if !(error is CancellationError) { disable("보정 경로 오류 · 빠른 STT 유지: " + error.localizedDescription) }
            // Cleanup must not inherit cancellation from the quality worker.
            let cleanup = Task { @MainActor in
                await self.pipeline.cancel()
                do { try await self.speech.finish(aborting: true) }
                catch { /* The initial quality error is already reported. */ }
            }
            await cleanup.value
        }
        await optional.cancel()
        // Cancelled SDK loaders can outlive their capture. Hold the lease until
        // they really exit, but do not make the user's Stop await those loaders.
        await optional.waitUntilFinished()
        closed = true; accepting = false; continuation?.finish(); continuation = nil
        budget = QualityAudioBudget()
    }

    private func deliver(_ value: PCMChunk) throws {
        try speech.append(value)
        observations.analyzerInputThrough = value.time + Double(value.buffer.frameLength)/value.buffer.format.sampleRate
        output(value)
    }

    func finish(aborting: Bool) async {
        let wasPreparing = hasStarted && !accepting && !closed
        if aborting || wasPreparing {
            closed = true; accepting = false; task?.cancel()
        }
        continuation?.finish(); continuation = nil
        await optional.cancel()
        // A loader/SDK preparation may ignore cancellation. It owns its cleanup,
        // and closed blocks all late delivery; stopping capture need not await it.
        if aborting || wasPreparing { return }
        let deadline = ProcessInfo.processInfo.systemUptime + finishTimeout
        while !consumerFinished {
            if Task.isCancelled {
                disable("입력 중지 · 보정 작업 취소 요청")
                task?.cancel(); return
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                observations.overloadStops += 1
                disable("입력 종료 후 보정 대기 시간 초과 · 원본 유지")
                task?.cancel(); return
            }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { disable("입력 중지 · 보정 작업 취소 요청"); task?.cancel(); return }
        }
        closed = true; accepting = false
    }
}
