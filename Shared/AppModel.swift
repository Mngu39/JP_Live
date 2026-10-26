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
        var timedSpans: [TimedTextSpan] = []
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
    private var currentSpeakerIdentityEpoch: Int?
    private var speakerMappingEpochStart: Double?
    private var liveDiarizationConnected = false
    private var pendingLiveAnalysis: (any SpeechAnalysisProvider)?
    private var liveAnalysisStatus = "화자 분석 준비 전"
    private var primarySpeechTrace: [SpeechResultTrace] = []
    private var diarizationDiagnostics = DiarizationDiagnostics()
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
    // SpeechTranscriber may keep more than one disjoint volatile source range alive
    // while resultsFinalizationTime advances separately. Keep those ranges in source
    // order; a single debounce slot can silently erase an earlier phrase.
    private var bufferedPrimaryResults: [BufferedSpeechResult] = []
    private var presentedPrimaryRange: (start: Double, end: Double)?
    private var primaryVolatileTask: Task<Void, Never>?
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

    func learningScreenshot(for caption: Caption) async -> [String: Any]? {
        #if PHASE2
        guard ScreenshotCapturePolicy.matches(caption: caption.captureID, current: captureID, running: running),
              let systemInput = input as? SystemAudioInput else { return nil }
        // Preserve the precise source instance; a Stop/Start may replace it
        // while ScreenCaptureKit is awaiting the one-frame screenshot.
        guard let screenshot = try? await systemInput.captureLearningScreenshot(
                  matchingSentenceStart: caption.semanticStart, end: caption.semanticEnd),
              ScreenshotCapturePolicy.matches(caption: caption.captureID, current: captureID, running: running),
              let currentInput = input as? SystemAudioInput, currentInput === systemInput else { return nil }
        return screenshot
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
        primaryVolatileTask?.cancel(); primaryVolatileTask = nil; bufferedPrimaryResults.removeAll(keepingCapacity: true); presentedPrimaryRange = nil
        speechTimeline = SpeechTimeline(); speakerHints = SoftSpeakerMapper(); currentSpeakerIdentityEpoch = nil; speakerMappingEpochStart = nil; audioThrough = nil
        liveDiarizationConnected = false; pendingLiveAnalysis = nil
        liveAnalysisStatus = "화자 분석 준비 중 · 기본 STT 유지"
        primarySpeechTrace.removeAll(keepingCapacity: true)
        diarizationDiagnostics = DiarizationDiagnostics(status: liveAnalysisStatus)
        refreshFeatureStatus()
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
        let speech = AppleSpeechEngine()
        // Speaker attribution is a live metadata path. Model preparation does
        // not block the Primary PCM loop.
        let liveAnalysisPreparation = OptionalProviderPreparation(serializeAnalysisPreparation: true)
        await liveAnalysisPreparation.startAvailable(analysis: true, enhancement: false)
        #if PHASE2
        separation = LiveSeparationPass(
            currentRows: { [weak self] in
                guard let self, self.captureID == capture else { return [] }
                return Array(self.captions.suffix(32).filter { $0.captureID == capture })
            },
            currentTimeline: { [weak self] in
                guard let self, self.captureID == capture else { return SpeechTimeline() }
                return self.speechTimeline
            },
            deliver: { [weak self] original, target, rows in
            guard let self, self.captureID == capture else { return [] }
            let ids = self.transcript.applySeparation(original: original, target: target, separated: rows)
            guard !ids.isEmpty else { return [] }
            // Every visual segment belongs to one semantic sentence. Invalidate all old
            // per-row work, then enqueue sentence translation only for the semantic anchor.
            self.translationJobs.invalidate(Array(Set(ids + [original.id])))
            for id in Set(ids + [original.id]) {
                self.translatedDraftSources[id] = nil
                self.morphologyTasks.removeValue(forKey: id)?.cancel()
                self.morphologyRequests[id] = nil; self.morphologySources[id] = nil
            }
            self.captionIndices.removeAll(keepingCapacity: true)
            self.enqueueTranslations(ids, language: language); self.scheduleMorphology(ids)
            return ids
        }, remap: { [weak self] ids, mapping in
            guard let self, self.captureID == capture else { return }
            if self.transcript.applySeparationLaneMapping(ids: ids, mapping: mapping) {
                self.refreshSpeakerPresentation()
            }
        })
        separationDiagnostics = separation?.diagnostics ?? SeparationDiagnostics()
        #endif
        var inputFailure: Error?
        do {
            try Task.checkCancellation()
            status = "Apple STT 준비 중…"
            try await speech.prepare(language: language, result: { [weak self] text, final, start, end, finalizedThrough, timedSpans in
                guard let self, self.captureID == capture else { return }
                self.recordPrimarySpeech(text: text, final: final, start: start, end: end,
                                         finalizedThrough: finalizedThrough, timedSpans: timedSpans)
                self.receivePrimarySpeech(.init(text: text, final: final, start: start, end: end,
                    finalizedThrough: finalizedThrough, timedSpans: timedSpans), language: language)
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

                    // Install live diarization only after its model is prepared. This runs
                    // beside the Primary STT path; the Primary pipeline remains realtime
                    // and never waits for analysis metadata.
                    let liveReady = await liveAnalysisPreparation.takeReady()
                    guard !Task.isCancelled, self.captureID == capture else { return }
                    if let analysis = liveReady.analysis {
                        // Handoff only. The serial PCM loop performs the one-time install
                        // between process calls so provider state cannot be swapped by a
                        // concurrently re-entrant AudioPreprocessor call.
                        self.pendingLiveAnalysis = analysis
                        self.liveAnalysisStatus = "화자 분석 준비됨 · 다음 PCM부터 연결"
                        self.diarizationDiagnostics.status = self.liveAnalysisStatus
                    } else if !self.liveDiarizationConnected && self.pendingLiveAnalysis == nil {
                        self.liveAnalysisStatus = liveReady.analysisStatus
                        self.diarizationDiagnostics.status = liveReady.analysisStatus
                    }
                    self.refreshFeatureStatus()

                    let analysisUpdates = await pipeline.takeAnalysisUpdates()
                    guard !Task.isCancelled, self.captureID == capture else { return }
                    self.applyAnalysisUpdates(analysisUpdates)
                    self.liveDiagnostics = self.makeLiveDiagnostics(input: inputProgress,
                        elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
                    let activityEnd = self.speechTimeline.latestEnd.map { min($0, self.audioThrough ?? $0) }
                    let activity = activityEnd.flatMap { self.speechTimeline.activity(through: $0) }
                    let now = ProcessInfo.processInfo.systemUptime
                    let ready = self.transcript.tick(now: now, activity: activity)
                    self.enqueueTranslations(ready, language: language)
                    self.queueDraftTranslation(language: language)
                    self.scheduleMorphology(ready + [self.transcript.draftRowID].compactMap { $0 })
                    self.separation?.consider(fastBacklog: inputProgress.pendingAudio)
                    if let separation = self.separation { self.separationDiagnostics = separation.diagnostics }
                }
            }
            for try await chunk in sequence {
                try Task.checkCancellation()
                if let prepared = pendingLiveAnalysis {
                    pendingLiveAnalysis = nil
                    await pipeline.installPrepared(analysis: prepared, enhancement: nil)
                    try Task.checkCancellation()
                    liveDiarizationConnected = true
                    liveAnalysisStatus = "화자 분석 연결됨 · 실시간 메타데이터"
                    diarizationDiagnostics.status = liveAnalysisStatus
                    refreshFeatureStatus()
                }
                let (processed, value) = try await pipeline.process(chunk)
                metrics = value
                if let analysisWarning = value.warnings.last(where: { $0.contains("화자 분석") }) {
                    liveAnalysisStatus = analysisWarning
                    diarizationDiagnostics.status = analysisWarning
                    refreshFeatureStatus()
                }
                for output in processed { rememberAudio(output); try speech.append(output) }
                newInput.progress?.processed(chunk)
            }
        } catch {
            if !(error is CancellationError) { inputFailure = error; status = error.localizedDescription }
        }
        // Natural EOF can arrive after the loader became ready but before another PCM
        // iteration had a chance to install it. Do one final mailbox handoff so the
        // retained ring is still backfilled instead of discarding all short-capture
        // diarization merely because there was no "next chunk". Manual Stop never waits.
        if !Task.isCancelled && inputFailure == nil {
            let finalReady = await liveAnalysisPreparation.takeReady()
            if pendingLiveAnalysis == nil { pendingLiveAnalysis = finalReady.analysis }
            if let prepared = pendingLiveAnalysis {
                pendingLiveAnalysis = nil
                await pipeline.installPrepared(analysis: prepared, enhancement: nil)
                liveDiarizationConnected = true
                liveAnalysisStatus = "화자 분석 연결됨 · EOF 백필"
                diarizationDiagnostics.status = liveAnalysisStatus
                refreshFeatureStatus()
            }
        }
        timerTask?.cancel(); timerTask = nil
        // Closing the per-capture live loader prevents any late model preparation from
        // attaching after Stop/EOF. Installed analysis is owned by `pipeline` and drains
        // normally on natural EOF. Stop never waits for a model download.
        await liveAnalysisPreparation.cancel()
        pendingLiveAnalysis = nil
        // Manual stop/error cancels overlap processing immediately. Natural EOF
        // keeps its PCM window until the final STT and analysis rows arrive.
        if Task.isCancelled || inputFailure != nil { separation?.stop() }
        await newInput.stop()
        let nativeStopFailure = newInput.stopFailure
        // Cleanup runs in a fresh task: cancelling the input loop must not also
        // cancel final conversion/STT finalization of already-accepted audio.
        let wasCancelled = Task.isCancelled
        // User Stop intentionally discards the screen/history immediately afterward.
        // Do not wait for accepted PCM on manual Stop.
        // Natural EOF still drains accepted audio so file/stream completion can finalize text.
        let drainAcceptedAudio = inputFailure == nil && !wasCancelled
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
        if !wasCancelled {
            // `pipeline.finish()` waits for live diarization to finish accepted PCM, so
            // this is the final authoritative speaker metadata drain for the capture.
            applyAnalysisUpdates(await pipeline.takeAnalysisUpdates())
        }
        if let nativeStopFailure { status = nativeStopFailure }
        else if inputFailure == nil, let cleanupFailure { status = cleanupFailure }
        let ready = finishPrimaryTranscript(language: language)
        enqueueTranslations(ready, language: language); queueDraftTranslation(language: language)
        scheduleMorphology(ready + captions.suffix(1).map(\.id))
        if let separation {
            if !Task.isCancelled && inputFailure == nil && cleanupFailure == nil {
                await separation.finish()
            } else {
                separation.stop()
            }
            separationDiagnostics = separation.diagnostics
        }
        separation = nil
        input = nil
        if Task.isCancelled && inputFailure == nil && cleanupFailure == nil && nativeStopFailure == nil {
            status = "입력 중지"
        }
        else if status == "듣는 중" { status = "입력 완료" }
        running = false
        liveDiagnostics = makeLiveDiagnostics(input: newInput.progress?.snapshot() ?? AudioInputSnapshot(),
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
    }

    func finishPrimaryTranscript(language: SourceLanguage) -> [UUID] {
        primaryVolatileTask?.cancel(); primaryVolatileTask = nil
        // Commit any leading ranges that Apple explicitly finalized. If an earlier
        // range is still tentative, later ranges cannot safely leapfrog it in
        // TranscriptBuffer; preserve the remaining source-order text as one
        // unconfirmed EOF draft instead of dropping all but the last callback.
        drainPrimaryQueue(language: language)
        if !bufferedPrimaryResults.isEmpty {
            let aggregate = aggregateBufferedPrimaryResults(language: language)
            bufferedPrimaryResults.removeAll(keepingCapacity: true)
            presentedPrimaryRange = nil
            if let aggregate { applyPrimarySpeech(aggregate, language: language) }
        }
        return transcript.finish()
    }

    func receivePrimarySpeech(_ result: BufferedSpeechResult, language: SourceLanguage) {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            let removedPresented = presentedPrimaryRange.map { rangesOverlap($0.start, $0.end, result.start, result.end) } ?? false
            bufferedPrimaryResults.removeAll { rangesOverlap($0.start, $0.end, result.start, result.end) }
            if removedPresented {
                primaryVolatileTask?.cancel(); primaryVolatileTask = nil
                presentedPrimaryRange = nil
                applyPrimarySpeech(result, language: language)
            }
            markPrimaryFinalized(through: result.finalizedThrough)
            drainPrimaryQueue(language: language)
            schedulePrimaryDebounce(language: language)
            return
        }

        // Replace only the recognizer hypothesis for the same/overlapping source
        // range. Disjoint volatile ranges coexist until their finalization frontier
        // advances; this is the state a one-slot debounce could not represent.
        var replacedPresented = false
        bufferedPrimaryResults.removeAll { existing in
            let sameStart = abs(existing.start-result.start) <= speechSourceTimeTolerance
            let overlaps = rangesOverlap(existing.start, existing.end, result.start, result.end)
            if sameStart || overlaps {
                if let shown = presentedPrimaryRange, rangesOverlap(shown.start, shown.end, existing.start, existing.end) {
                    replacedPresented = true
                }
                return true
            }
            return false
        }
        if replacedPresented {
            primaryVolatileTask?.cancel(); primaryVolatileTask = nil
            presentedPrimaryRange = nil
        }
        bufferedPrimaryResults.append(result)
        bufferedPrimaryResults.sort { lhs, rhs in
            if abs(lhs.start-rhs.start) > speechSourceTimeTolerance { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
        markPrimaryFinalized(through: result.finalizedThrough)
        drainPrimaryQueue(language: language)
        schedulePrimaryDebounce(language: language)
    }

    private func markPrimaryFinalized(through frontier: Double?) {
        guard let frontier, frontier.isFinite else { return }
        for index in bufferedPrimaryResults.indices where bufferedPrimaryResults[index].end <= frontier + speechSourceTimeTolerance {
            bufferedPrimaryResults[index].final = true
        }
    }

    private func drainPrimaryQueue(language: SourceLanguage) {
        while let first = bufferedPrimaryResults.first, first.final {
            var committed = first; committed.final = true
            applyPrimarySpeech(committed, language: language)
            bufferedPrimaryResults.removeFirst()
            if let shown = presentedPrimaryRange, rangesOverlap(shown.start, shown.end, first.start, first.end) {
                presentedPrimaryRange = nil
            }
        }
    }

    private func schedulePrimaryDebounce(language: SourceLanguage) {
        guard let first = bufferedPrimaryResults.first, !first.final else { return }
        if let shown = presentedPrimaryRange,
           abs(shown.start-first.start) <= speechSourceTimeTolerance,
           abs(shown.end-first.end) <= speechSourceTimeTolerance { return }
        primaryVolatileTask?.cancel()
        let expectedStart = first.start, expectedEnd = first.end
        let debounceMilliseconds = Int(primaryVolatileDebounce * 1000)
        primaryVolatileTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(debounceMilliseconds)) } catch { return }
            guard let self, let current = self.bufferedPrimaryResults.first, !current.final,
                  abs(current.start-expectedStart) <= self.speechSourceTimeTolerance,
                  abs(current.end-expectedEnd) <= self.speechSourceTimeTolerance else { return }
            self.primaryVolatileTask = nil
            self.applyPrimarySpeech(current, language: language)
            self.presentedPrimaryRange = (current.start, current.end)
        }
    }

    private func aggregateBufferedPrimaryResults(language: SourceLanguage) -> BufferedSpeechResult? {
        let values = bufferedPrimaryResults.sorted { $0.start < $1.start }
        guard let first = values.first, let last = values.last else { return nil }
        var text = ""
        for value in values {
            let piece = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if language == .english, !text.isEmpty, text.last?.isWhitespace == false, piece.first?.isWhitespace == false { text += " " }
            text += piece
        }
        guard !text.isEmpty else { return nil }
        return BufferedSpeechResult(text: text, final: false, start: first.start, end: last.end,
                                    finalizedThrough: nil, timedSpans: [])
    }

    private func rangesOverlap(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Bool {
        aStart < bEnd-speechSourceTimeTolerance && bStart < aEnd-speechSourceTimeTolerance
    }

    private func applyPrimarySpeech(_ result: BufferedSpeechResult, language: SourceLanguage) {
        let ready = transcript.receive(result.text, final: result.final, start: result.start, end: result.end,
            speaker: speechTimeline.speaker(start: result.start, end: result.end),
            now: ProcessInfo.processInfo.systemUptime, finalizedThrough: result.finalizedThrough,
            timedSpans: result.timedSpans)
        enqueueTranslations(ready, language: language)
        queueDraftTranslation(language: language)
        scheduleMorphology(ready + [transcript.draftRowID].compactMap { $0 })
    }

    private func rememberAudio(_ output: PCMChunk) {
        separation?.offer(output)
        let end = output.time + Double(output.buffer.frameLength)/output.buffer.format.sampleRate
        audioThrough = end
        // Render-time decisions are leveler metadata only. Authoritative speaker history
        // comes exclusively from takeAnalysisUpdates(); otherwise a current render slice
        // can enter the append-only global timeline before delayed backfill and erase it.
    }

    private func applyAnalysisUpdates(_ decisions: [SpeechDecision]) {
        let valid = decisions.filter(\.isValid)
        guard !valid.isEmpty else { return }
        recordDiarization(valid)
        let previousTimelineEnd = speechTimeline.latestEnd
        speechTimeline.append(valid)
        // LS-EEND slot numbers are only meaningful inside one recurrent-state epoch.
        // A recovery/reset deliberately renews that namespace; do not let the old
        // two-track presentation mapper assign a post-reset slot the opposite tint.
        if let newestEpoch = valid.last?.identityEpoch, currentSpeakerIdentityEpoch != newestEpoch {
            if currentSpeakerIdentityEpoch != nil {
                speakerHints = SoftSpeakerMapper()
                if let firstNew = valid.first(where: { $0.identityEpoch == newestEpoch })?.start {
                    speakerMappingEpochStart = max(previousTimelineEnd ?? firstNew, firstNew)
                } else { speakerMappingEpochStart = previousTimelineEnd }
            }
            currentSpeakerIdentityEpoch = newestEpoch
        }
        _ = transcript.applySpeakerTimeline(speechTimeline)
        refreshSpeakerPresentation()
    }

    // Speaker evidence may arrive after the caption. First let recent final rows teach the
    // two-track presentation mapper; once both tracks are confirmed, recolor the same
    // recent rows retroactively. Separator lanes use global colors only when a
    // non-overlap live-diarizer anchor mapped that local lane to a real speaker slot.
    private func refreshSpeakerPresentation() {
        let minimumEnd = speakerMappingEpochStart.map { $0 + speechSourceTimeTolerance }
        let indices = transcript.recentFinalSpeakerRowIndices(captureID: captureID, minimumEnd: minimumEnd)
        for index in indices where transcript.rows[index].separationGroup == nil {
            _ = speakerHints.hint(for: transcript.rows[index])
        }
        for index in indices {
            let row = transcript.rows[index]
            let hint: SpeakerGutterHint
            if row.separationGroup != nil {
                hint = row.speaker.map { speakerHints.resolvedHint(slot: $0) } ?? .mixed
                if transcript.rows[index].gutterHint != hint {
                    transcript.rows[index].gutterHint = hint
                    transcript.rows[index].revision += 1
                }
                continue
            }
            let spanSlots = Set(row.speakerSpans.compactMap(\.speaker))
            let spanEpochs = Set(row.speakerSpans.map(\.identityEpoch))
            if row.speakerSpans.contains(where: { $0.overlap }) || spanSlots.count > 1 ||
                spanEpochs.count > 1 ||
                (row.speaker == nil && spanSlots.isEmpty &&
                 speechTimeline.hasMultipleSpeakersOrOverlap(start: row.start, end: row.end)) {
                hint = .mixed
            } else {
                hint = speakerHints.resolvedHint(slot: row.speaker ?? spanSlots.first)
            }
            if transcript.rows[index].gutterHint != hint {
                transcript.rows[index].gutterHint = hint
                transcript.rows[index].revision += 1
            }
        }
    }

    private func recordPrimarySpeech(text: String, final: Bool, start: Double, end: Double,
                                     finalizedThrough: Double?, timedSpans: [TimedTextSpan]) {
        appendSpeechTrace(&primarySpeechTrace, text: text, final: final, start: start, end: end,
                          finalizedThrough: finalizedThrough, timedSpans: timedSpans)
    }

    private func appendSpeechTrace(_ trace: inout [SpeechResultTrace], text: String, final: Bool,
                                   start: Double, end: Double, finalizedThrough: Double?,
                                   timedSpans: [TimedTextSpan]) {
        trace.append(.init(text: text, final: final, start: start, end: end,
                           finalizedThrough: finalizedThrough, timedSpans: timedSpans))
        if trace.count > 48 { trace.removeFirst(trace.count-48) }
    }

    private func recordDiarization(_ decisions: [SpeechDecision]) {
        let valid = decisions.filter(\.isValid)
        guard !valid.isEmpty else { return }
        diarizationDiagnostics.status = "화자 분석 동작 중"
        diarizationDiagnostics.analysisActivatedAt = diarizationDiagnostics.analysisActivatedAt ?? valid.first?.start
        diarizationDiagnostics.updateCount += valid.count
        diarizationDiagnostics.singleSpeakerFrames += valid.filter {
            $0.speechProbability >= 0.60 && $0.activeSpeakers == 1 && $0.speakerSlot != nil
        }.count
        diarizationDiagnostics.overlapFrames += valid.filter {
            $0.speechProbability >= 0.60 && $0.activeSpeakers >= 2
        }.count
        var slots = Set(diarizationDiagnostics.distinctSpeakerSlots)
        slots.formUnion(valid.compactMap {
            $0.speechProbability >= 0.60 && $0.activeSpeakers == 1 ? $0.speakerSlot : nil
        })
        diarizationDiagnostics.distinctSpeakerSlots = slots.sorted()
        diarizationDiagnostics.latestEnd = max(diarizationDiagnostics.latestEnd ?? 0, valid.map(\.end).max() ?? 0)
        diarizationDiagnostics.recentFrames += valid.map {
            DiarizationFrameTrace(speechProbability: $0.speechProbability, activeSpeakers: $0.activeSpeakers,
                                  start: $0.start, end: $0.end, speakerSlot: $0.speakerSlot,
                                  identityEpoch: $0.identityEpoch)
        }
        if diarizationDiagnostics.recentFrames.count > 96 {
            diarizationDiagnostics.recentFrames.removeFirst(diarizationDiagnostics.recentFrames.count-96)
        }
    }

    private func refreshFeatureStatus() {
        let value = liveAnalysisStatus
        if featureStatus != value { featureStatus = value }
    }

    private func makeLiveDiagnostics(input: AudioInputSnapshot, elapsed: Double) -> LivePipelineDiagnostics {
        let displayed = captions.suffix(32).map { row in
            DisplayedCaptionTrace(text: row.source, final: row.isFinal, start: row.start, end: row.end,
                speaker: row.speaker, gutter: row.gutterHint.rawValue,
                separated: row.separationGroup != nil, separationLane: row.separationLane,
                speakerSpans: row.speakerSpans)
        }
        return LivePipelineDiagnostics(input: input,
            captionCount: captions.count, elapsed: elapsed, primarySpeech: primarySpeechTrace,
            displayedCaptions: displayed, diarization: diarizationDiagnostics,
            separation: separationDiagnostics)
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
        primarySpeechTrace.removeAll(keepingCapacity: true)
        liveDiagnostics.primarySpeech = []; liveDiagnostics.displayedCaptions = []
        primaryVolatileTask?.cancel(); primaryVolatileTask = nil; bufferedPrimaryResults.removeAll(keepingCapacity: true); presentedPrimaryRange = nil; currentSpeakerIdentityEpoch = nil; speakerMappingEpochStart = nil; speakerHints = SoftSpeakerMapper()
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
            _ = speakerHints.hint(for: transcript.rows[index])
        }
        refreshSpeakerPresentation()
        let translationIDs = ids.compactMap { id -> UUID? in
            guard let index = captionIndex(id, matching: { $0.id == id && $0.isFinal && $0.isSemanticSentenceAnchor }) else { return nil }
            return transcript.rows[index].id
        }
        translationJobs.enqueue(Array(Set(translationIDs)), language: language)
        if translationPreparationFailed && self.language == language {
            let pending = Set(translationIDs)
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
                guard let row = caption(id, matching: {
                    $0.id == id && $0.isFinal && $0.language == sessionLanguage && $0.isSemanticSentenceAnchor
                }) else { translationJobs.complete(id); continue }
                do {
                    let response = try await session.translate(row.semanticSource)
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
                    // A transcript replacement/Clear invalidated the old job. Its
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
            $0.isFinal && $0.language == request.language && $0.isSemanticSentenceAnchor &&
            $0.semanticID == request.semanticID && $0.semanticSource == request.semanticSource
        }
    }

    // Sentence popup may survive an asynchronous overlap replacement because the original
    // row ID is deliberately retained on the semantic anchor. Word popup/save is stricter:
    // token offsets belong to one visual source row, so a changed/replaced row invalidates it.
    func popupCaption(rowID: UUID, captureID: UUID, expectedSource: String, sentenceMode: Bool) -> Caption? {
        guard let index = captionIndex(rowID, matching: { $0.id == rowID && $0.captureID == captureID }) else { return nil }
        let current = transcript.rows[index]
        if !sentenceMode {
            guard current.source == expectedSource else { return nil }
            return current
        }
        return PopupSemanticSentence.resolve(current: current, rows: transcript.rows, currentIndex: index)
    }
}
