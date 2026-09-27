import XCTest
import AVFoundation
@testable import JPLive

final class CoreTests: XCTestCase {
    @MainActor
    func testPrimaryEOFPreservesLatestDebouncedVolatileAsUnconfirmed() {
        let model = AppModel()
        defer { model.clearTranscript() }
        model.receivePrimarySpeech(.init(text: "古い仮説", final: false, start: 0, end: 1), language: .japanese)
        model.receivePrimarySpeech(.init(text: "最後の仮説", final: false, start: 0, end: 1), language: .japanese)
        XCTAssertTrue(model.captions.isEmpty, "Result is still waiting for debounce")
        XCTAssertTrue(model.finishPrimaryTranscript(language: .japanese).isEmpty)
        XCTAssertEqual(model.captions.count, 1)
        XCTAssertEqual(model.captions.first?.source, "最後の仮説")
        XCTAssertEqual(model.captions.first?.isFinal, false)
        XCTAssertEqual(model.captions.first?.translationError, "인식 종료 · 미확정 원문")
    }

    @MainActor
    func testClearPreventsDebouncedSpeechFromReturningAtEOF() {
        let model = AppModel()
        model.receivePrimarySpeech(.init(text: "消した仮説", final: false, start: 0, end: 1), language: .japanese)
        model.clearTranscript()
        _ = model.finishPrimaryTranscript(language: .japanese)
        XCTAssertTrue(model.captions.isEmpty)
    }

    @MainActor
    func testClearWatermarkCoversCapturedButNotYetProcessedAudio() {
        XCTAssertEqual(AppModel.clearWatermark(processedThrough: 3, capturedThrough: 5), 5)
        XCTAssertEqual(AppModel.clearWatermark(processedThrough: 7, capturedThrough: 5), 7)
        XCTAssertEqual(AppModel.clearWatermark(processedThrough: nil, capturedThrough: 5), 5)
        XCTAssertEqual(AppModel.clearWatermark(processedThrough: 3, capturedThrough: nil), 3)
        XCTAssertNil(AppModel.clearWatermark(processedThrough: .nan, capturedThrough: .infinity))
    }

    @MainActor
    func testFinalSpeechSupersedesBufferedVolatileBeforeEOF() {
        let model = AppModel()
        defer { model.clearTranscript() }
        model.receivePrimarySpeech(.init(text: "古い仮説", final: false, start: 0, end: 1), language: .japanese)
        model.receivePrimarySpeech(.init(text: "確定した文。", final: true, start: 0, end: 1), language: .japanese)
        _ = model.finishPrimaryTranscript(language: .japanese)
        XCTAssertEqual(model.captions.map(\.source), ["確定した文。"])
        XCTAssertTrue(model.captions.allSatisfy(\.isFinal))
    }

    @MainActor
    func testDebounceCannotDropPriorPhraseFinalizedByNextResult() {
        let model = AppModel()
        defer { model.clearTranscript() }
        // Both callbacks arrive before the 150 ms visual debounce can fire. Apple may
        // finalize the first phrase only by advancing resultsFinalizationTime on the next
        // result, without re-emitting the first text with isFinal == true.
        model.receivePrimarySpeech(.init(text: "今日は", final: false, start: 0, end: 1, finalizedThrough: 0),
                                   language: .japanese)
        model.receivePrimarySpeech(.init(text: "晴れ。", final: true, start: 1, end: 2, finalizedThrough: 2),
                                   language: .japanese)
        XCTAssertEqual(model.captions.map(\.source), ["今日は晴れ。"])
        XCTAssertTrue(model.captions.allSatisfy(\.isFinal))
    }

    func testSeparatedGutterColorsDoNotMutateDiarizerTracking() {
        var mapper = SoftSpeakerMapper()
        _ = mapper.hint(slot: 7, start: 0, end: 1)
        var control = mapper
        var row = Caption(captureID: UUID(), language: .japanese, source: "分離。", start: 100, end: 101,
                          isFinal: true, speaker: 0, gutterHint: .first, separationGroup: UUID())
        XCTAssertEqual(mapper.hint(for: row), .first)
        row.speaker = 1; row.gutterHint = .second
        XCTAssertEqual(mapper.hint(for: row), .second)
        for index in 1...8 {
            let start = Double(index)
            XCTAssertEqual(mapper.hint(slot: index % 2, start: start, end: start+1),
                           control.hint(slot: index % 2, start: start, end: start+1))
        }
    }

    @MainActor
    func testQualityEOFBudgetReturnsWithoutReleasingUnfinishedNativeWork() async {
        let setup = OptionalProviderPreparation()
        await setup.start(analysis: nil, enhancement: nil)
        let sink = TestQualitySpeechSink(holdPreparation: false, holdFinish: true)
        var delivered = 0
        let pass = QualitySpeechPass(pipeline: AudioPreprocessor(), language: .japanese, speech: sink,
            optional: setup, finishTimeout: 0.01, result: { _, _, _, _, _ in delivered += 1 },
            output: { _ in }, status: { _ in })
        pass.offer(Self.pcm(count: 4800, time: 0))
        await sink.waitUntilPreparationStarted()
        for _ in 0..<100 { if pass.acceptingInput { break }; await Task.yield() }
        XCTAssertTrue(pass.acceptingInput)
        await pass.finish(aborting: false)
        XCTAssertEqual(pass.diagnostics.overloadStops, 1)
        sink.emitResult(); XCTAssertEqual(delivered, 0)
        let nextSetup = OptionalProviderPreparation()
        await nextSetup.start(analysis: nil, enhancement: nil)
        let next = QualitySpeechPass(pipeline: AudioPreprocessor(), language: .japanese,
            speech: TestQualitySpeechSink(holdPreparation: false), optional: nextSetup,
            result: { _, _, _, _, _ in XCTFail("Overlapping quality pass") }, output: { _ in }, status: { _ in })
        next.offer(Self.pcm(count: 4800, time: 0))
        XCTAssertFalse(next.acceptingInput)
        XCTAssertTrue(next.diagnostics.stoppedReason?.contains("이전 보정 작업") == true)
        sink.releaseFinish()
        // The first finish intentionally uses a 10 ms budget to force the timeout path.
        // After releasing the synthetic native finish gate, wait independently for the
        // cancelled worker to unwind and release the process-wide lease. Reusing the same
        // 10 ms finish budget here made this test scheduler-dependent on GitHub runners.
        var released = false
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let probe = UUID()
            if QualityWorkLease.acquire(probe) {
                QualityWorkLease.release(probe)
                released = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(released, "Quality worker did not release its lease after native finish resumed")
        await next.finish(aborting: true)
    }

    @MainActor
    func testCancellationDuringQualityEOFDoesNotAwaitUncooperativeFinish() async {
        let setup = OptionalProviderPreparation()
        await setup.start(analysis: nil, enhancement: nil)
        let sink = TestQualitySpeechSink(holdPreparation: false, holdFinish: true)
        let pass = QualitySpeechPass(pipeline: AudioPreprocessor(), language: .japanese, speech: sink,
            optional: setup, result: { _, _, _, _, _ in }, output: { _ in }, status: { _ in })
        pass.offer(Self.pcm(count: 4800, time: 0))
        await sink.waitUntilPreparationStarted()
        for _ in 0..<100 { if pass.acceptingInput { break }; await Task.yield() }
        XCTAssertTrue(pass.acceptingInput)
        let ending = Task { await pass.finish(aborting: false) }
        await sink.waitUntilFinishStarted()
        ending.cancel()
        await ending.value
        XCTAssertFalse(pass.acceptingInput)
        XCTAssertEqual(pass.diagnostics.overloadStops, 0)
        sink.releaseFinish()
        await pass.finish(aborting: false)
    }

    @MainActor
    func testQualityLeaseIncludesCancelledModelLoaderUntilItActuallyExits() async {
        let setup = OptionalProviderPreparation(), gate = SuspendedPreparation()
        await setup.start(analysis: {
            await gate.suspend()
            return PatternAnalysis()
        }, enhancement: nil)
        await gate.waitUntilStarted()
        let sink = TestQualitySpeechSink(holdPreparation: false)
        let pass = QualitySpeechPass(pipeline: AudioPreprocessor(), language: .japanese, speech: sink,
            optional: setup, result: { _, _, _, _, _ in }, output: { _ in }, status: { _ in })
        pass.offer(Self.pcm(count: 4800, time: 0))
        await sink.waitUntilPreparationStarted()
        await pass.finish(aborting: true)
        let lease = UUID()
        XCTAssertFalse(QualityWorkLease.acquire(lease), "Cancelled loader still owns native work")
        await gate.release()
        await pass.finish(aborting: false)
        XCTAssertTrue(QualityWorkLease.acquire(lease))
        QualityWorkLease.release(lease)
    }

    @MainActor
    func testSeparationEOFConsidersFinalRowsWithoutLoadingMissingPCM() async {
        let pass = LiveSeparationPass(modelURL: URL(fileURLWithPath: "/unavailable/Separator.mlmodelc")) { _, _ in
            XCTFail("No PCM must not produce separated rows"); return false
        }
        var timeline = SpeechTimeline()
        timeline.append((0..<3).map { .init(speechProbability: 0.9, activeSpeakers: 2,
            start: Double($0)*0.1, end: Double($0+1)*0.1) })
        let row = Caption(captureID: UUID(), language: .japanese, source: "最後の会話。", start: 0, end: 0.3, isFinal: true)
        await pass.finish(rows: [row], timeline: timeline)
        XCTAssertEqual(pass.diagnostics.skipped, 1)
        XCTAssertEqual(pass.diagnostics.attempted, 0)
        XCTAssertFalse(pass.diagnostics.busy)
        XCTAssertEqual(pass.diagnostics.status, "입력 종료 · 분리 처리 종료")
        pass.consider([row], timeline: timeline, fastBacklog: 0)
        XCTAssertEqual(pass.diagnostics.skipped, 1, "EOF must close the pass")
    }

    @MainActor
    func testExplicitStopPreventsEOFSeparationScheduling() async {
        let pass = LiveSeparationPass(modelURL: URL(fileURLWithPath: "/unavailable/Separator.mlmodelc")) { _, _ in
            XCTFail("Stopped pass must not deliver rows"); return false
        }
        var timeline = SpeechTimeline()
        timeline.append((0..<3).map { .init(speechProbability: 0.9, activeSpeakers: 2,
            start: Double($0)*0.1, end: Double($0+1)*0.1) })
        let row = Caption(captureID: UUID(), language: .japanese, source: "最後の会話。", start: 0, end: 0.3, isFinal: true)
        pass.stop()
        await pass.finish(rows: [row], timeline: timeline)
        XCTAssertEqual(pass.diagnostics.skipped, 0)
        XCTAssertEqual(pass.diagnostics.attempted, 0)
    }

    @MainActor
    func testSeparationLeaseBlocksRestartUntilOriginalWorkActuallyExits() {
        let old = UUID(), next = UUID()
        defer { SeparationWorkLease.release(old); SeparationWorkLease.release(next) }
        XCTAssertTrue(SeparationWorkLease.acquire(old))
        XCTAssertFalse(SeparationWorkLease.acquire(next))
        SeparationWorkLease.release(next)
        XCTAssertFalse(SeparationWorkLease.acquire(next))
        SeparationWorkLease.release(old)
        XCTAssertTrue(SeparationWorkLease.acquire(next))
    }
    func testSeparationStitcherRestoresSwappedLanesAndExactOverlap() throws {
        let length = SeparationStitcher.window + SeparationStitcher.hop
        let first = (0..<length).map { Float(sin(Double($0)*0.01))*0.1 }
        let second = (0..<length).map { Float(cos(Double($0)*0.017))*0.1 }
        var stitcher = SeparationStitcher()
        try stitcher.append([Array(first.prefix(64000)), Array(second.prefix(64000))])
        try stitcher.append([Array(second.suffix(64000)), Array(first.suffix(64000))])
        XCTAssertEqual(stitcher.stems[0].count, length)
        for index in 0..<length {
            XCTAssertEqual(stitcher.stems[0][index], first[index], accuracy: 0.00001)
            XCTAssertEqual(stitcher.stems[1][index], second[index], accuracy: 0.00001)
        }
    }

    func testSeparationStitcherRejectsAmbiguousAndInvalidWindows() throws {
        let same = [Float](repeating: 0.01, count: 64000)
        var stitcher = SeparationStitcher()
        try stitcher.append([same, same])
        XCTAssertThrowsError(try stitcher.append([same, same]))
        XCTAssertEqual(stitcher.stems[0].count, 64000)
        XCTAssertThrowsError(try stitcher.append([[.nan], [.nan]]))
    }

    func testSeparationReplacementIsAtomicAndProtectedFromMixedRevision() {
        let capture = UUID()
        let original = Caption(captureID: capture, language: .japanese, source: "混ざった文。", translation: "기존 번역", start: 10, end: 12, isFinal: true)
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [original]
        let a = Caption(captureID: UUID(), language: .japanese, source: "こんにちは。", start: 10, end: 12, isFinal: true, speaker: 0)
        let b = Caption(captureID: UUID(), language: .japanese, source: "こんばんは。", start: 10.1, end: 11.5, isFinal: true, speaker: 1)
        XCTAssertTrue(buffer.applySeparation(original: original, separated: [a]).isEmpty)
        XCTAssertEqual(buffer.rows[0].translation, "기존 번역")
        let ids = buffer.applySeparation(original: original, separated: [a,b])
        XCTAssertEqual(ids.count, 2); XCTAssertEqual(ids[0], original.id)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(buffer.rows[0].separationGroup, buffer.rows[1].separationGroup)
        XCTAssertNotNil(buffer.rows[0].separationGroup)
        XCTAssertTrue(buffer.rows.allSatisfy { $0.captureID == capture && $0.translation.isEmpty })
        var mixed = original; mixed.source = "遅れて届いた混合文。"
        XCTAssertNil(buffer.applyRevision(mixed))
        XCTAssertTrue(buffer.applySeparation(original: original, separated: [a,b]).isEmpty)
    }

    func testSeparationRejectsStaleClearAndOutOfRangeResults() {
        let capture = UUID()
        let original = Caption(captureID: capture, language: .japanese, source: "元の文。", start: 0, end: 1, isFinal: true)
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [original]
        var a = original; a.source = "最初。"; a.speaker = 0
        var b = original; b.source = "次。"; b.speaker = 1; b.end = 2
        XCTAssertTrue(buffer.applySeparation(original: original, separated: [a,b]).isEmpty)
        b.end = 1; buffer.rows[0].source = "変更後。"
        XCTAssertTrue(buffer.applySeparation(original: original, separated: [a,b]).isEmpty)
        buffer.clearDisplay(through: 1)
        XCTAssertTrue(buffer.applySeparation(original: original, separated: [a,b]).isEmpty)
        XCTAssertTrue(buffer.rows.isEmpty)
    }

    @MainActor
    func testLiveSeparationRequiresCoveredOverlapAndExcludesThreeSpeakers() {
        var timeline = SpeechTimeline()
        timeline.append((0..<3).map { .init(speechProbability: 0.9, activeSpeakers: 2,
            start: Double($0)*0.1, end: Double($0+1)*0.1) })
        var row = Caption(captureID: UUID(), language: .japanese, source: "会話。", start: 0, end: 0.3, isFinal: true)
        XCTAssertTrue(LiveSeparationPass.eligible(row, timeline: timeline))
        timeline.append([.init(speechProbability: 0.9, activeSpeakers: 3, start: 0.3, end: 0.4)])
        row.end = 0.4
        XCTAssertFalse(LiveSeparationPass.eligible(row, timeline: timeline))
        row.end = 0.5
        XCTAssertFalse(LiveSeparationPass.eligible(row, timeline: timeline))
        row.end = 0.3; row.separationGroup = UUID()
        XCTAssertFalse(LiveSeparationPass.eligible(row, timeline: timeline))
    }

    @MainActor
    func testMissingSeparationModelNeverClaimsWorkOrDeliversRows() {
        let pass = LiveSeparationPass(modelURL: nil) { _, _ in
            XCTFail("Missing models must not produce separation output"); return false
        }
        var timeline = SpeechTimeline()
        timeline.append((0..<3).map { .init(speechProbability: 0.9, activeSpeakers: 2,
            start: Double($0)*0.1, end: Double($0+1)*0.1) })
        let row = Caption(captureID: UUID(), language: .japanese, source: "会話。", start: 0, end: 0.3, isFinal: true)
        pass.consider([row], timeline: timeline, fastBacklog: 0)
        XCTAssertEqual(pass.diagnostics.attempted, 0)
        XCTAssertFalse(pass.diagnostics.busy)
        XCTAssertEqual(pass.diagnostics.completed, 0)
        pass.clear(); pass.stop()
    }

    func testSeparationPCMWindowIsBoundedAndDoesNotBridgeGaps() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        func chunk(_ time: Double) -> PCMChunk {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            return PCMChunk(buffer: buffer, time: time)
        }
        var ring = SeparationAudioWindow()
        ring.append(chunk(0)); ring.append(chunk(0.02))
        XCTAssertNil(ring.covering(start: 0, end: 0.03))
        ring = SeparationAudioWindow()
        for index in 0..<3500 { ring.append(chunk(Double(index)/100)) }
        XCTAssertLessThanOrEqual(ring.count, 3202)
        XCTAssertNil(ring.covering(start: 0, end: 1))
        XCTAssertNotNil(ring.covering(start: 34, end: 35))
        XCTAssertNil(ring.covering(start: 3, end: 35))
    }

    func testStemLevelingBoostsQuietSpeechButNotNoiseOrOtherStem() throws {
        let quiet = [Float](repeating: 0.01, count: 4096)
        let speech = try StemLeveling.process(quiet, probabilities: [0.9])
        let noise = try StemLeveling.process(quiet, probabilities: [0.1])
        XCTAssertGreaterThan(speech.last!, quiet.last! * 3)
        XCTAssertEqual(noise, quiet)
        XCTAssertEqual(speech.count, quiet.count)
    }

    func testStemLevelingDoesNotCarrySpeechGainIntoNoiseAndPreservesShortTail() throws {
        let samples = [Float](repeating: 0.01, count: 4096 + 37)
        let result = try StemLeveling.process(samples, probabilities: [0.9, 0.1])
        XCTAssertEqual(result.count, samples.count)
        XCTAssertEqual(Array(result.suffix(37)), Array(samples.suffix(37)))
        XCTAssertTrue(result.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
    }

    func testStemLevelingRejectsMissingMisalignedAndInvalidVAD() {
        let samples = [Float](repeating: 0.01, count: 4097)
        XCTAssertThrowsError(try StemLeveling.process(samples, probabilities: []))
        XCTAssertThrowsError(try StemLeveling.process(samples, probabilities: [0.9]))
        XCTAssertThrowsError(try StemLeveling.process(samples, probabilities: [0.9, .nan]))
        XCTAssertThrowsError(try StemLeveling.process(samples, probabilities: [0.9, 1.1]))
        XCTAssertThrowsError(try StemLeveling.process([.infinity], probabilities: [0.9]))
    }

    func testOverlapGateRejectsInvalidConfidenceAndSaturates() {
        var gate = OverlapGate()
        for _ in 0..<100 { _ = gate.observe(activeSpeakers: 2, probability: 0.9) }
        XCTAssertEqual(gate.consecutive, 3)
        XCTAssertFalse(gate.observe(activeSpeakers: 2, probability: .infinity))
        XCTAssertFalse(gate.observe(activeSpeakers: 2, probability: 1.1))
        XCTAssertEqual(gate.consecutive, 0)
    }

    func testSudachiPreferenceDefaultsToCAndPersistsEachSupportedMode() {
        let suite = "JP-Live.Tests.SplitMode." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SudachiSplitMode.stored(in: defaults), .c)
        for mode in SudachiSplitMode.allCases {
            defaults.set(mode.rawValue, forKey: SudachiSplitMode.preferenceKey)
            XCTAssertEqual(SudachiSplitMode.stored(in: defaults), mode)
        }
        defaults.set("invalid", forKey: SudachiSplitMode.preferenceKey)
        XCTAssertEqual(SudachiSplitMode.stored(in: defaults), .c)
        XCTAssertEqual(SudachiSplitMode.allCases.map(\.bridgeValue), [0, 1, 2])
    }

    func testMorphologyModesPreserveUnicodeSourceAndRanges() async throws {
        let worker = MorphologyWorker()
        let source = "🎮東京都でゲームをします。"
        for mode in SudachiSplitMode.allCases {
            let result = try await worker.analyze(source, language: .japanese, mode: mode)
            XCTAssertEqual(result.tokens.map(\.surface).joined(), source)
            var cursor = 0
            for token in result.tokens {
                XCTAssertEqual(token.start, cursor)
                let range = try XCTUnwrap(Range(NSRange(location: token.start, length: token.end-token.start), in: source))
                XCTAssertEqual(String(source[range]), token.surface)
                cursor = token.end
            }
            XCTAssertEqual(cursor, source.utf16.count)
            if !LocalTokenizer.nativeBridgeLinked {
                XCTAssertNotNil(result.warning)
                XCTAssertEqual(result.engine, "Apple NaturalLanguage")
            }
        }
    }
    #if PHASE2
    func testRequiredPhase2NativeSudachiLoadsBundledDictionaryAndSplitsABC() throws {
        XCTAssertTrue(LocalTokenizer.nativeBridgeLinked, "Phase 2 must link SudachiBridge; Apple fallback is not a native integration pass")
        let a = try LocalTokenizer.nativeTokens("国家公務員", mode: .a)
        let b = try LocalTokenizer.nativeTokens("国家公務員", mode: .b)
        let c = try LocalTokenizer.nativeTokens("国家公務員", mode: .c)
        XCTAssertGreaterThanOrEqual(a.count, b.count)
        XCTAssertGreaterThanOrEqual(b.count, c.count)
        XCTAssertGreaterThan(a.count, c.count)
        for tokens in [a, b, c] { XCTAssertEqual(tokens.map(\.surface).joined(), "国家公務員") }
    }
    #endif
    #if PHASE2
    @MainActor
    func testDeviceValidationMetricsPassContinuousCaptureThroughAnalyzerInput() {
        let metrics = DeviceValidationMetricStore(startedAt: Date(timeIntervalSince1970: 0), startedUptime: 10)
        metrics.markSTTPrepared()
        metrics.markCaptureRequested(observedAt: 10)
        let raw = DeviceValidationAudioFormat(sampleRate: 48000, channels: 2, sampleFormat: "float32", interleaved: false)
        let processed = DeviceValidationAudioFormat(sampleRate: 48000, channels: 1, sampleFormat: "float32", interleaved: false)
        let analyzer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let analyzerBuffer = AVAudioPCMBuffer(pcmFormat: analyzer, frameCapacity: 160000)!
        analyzerBuffer.frameLength = 160000

        metrics.recordRaw(time: 0, frames: 480000, format: raw, observedAt: 10.1)
        metrics.recordProcessed(time: 0, frames: 480000, format: processed)
        metrics.recordSpeechAppend(frames: 480000)
        metrics.recordAnalyzerInput(buffer: analyzerBuffer, startTime: .zero)
        metrics.recordPipelineMetrics(AudioMetrics(rmsDB: -18, peakDB: -3))
        metrics.recordSpeechResult(final: true, observedAt: 10.5)

        let report = metrics.finish(userStopped: true, endedAt: Date(timeIntervalSince1970: 10), endedUptime: 20)
        XCTAssertEqual(report.verdict, .pass)
        XCTAssertEqual(report.rawGapCount, 0)
        XCTAssertEqual(report.rawOverlapCount, 0)
        XCTAssertEqual(report.processedFrames, report.speechAppendFrames)
        XCTAssertEqual(report.analyzerChunks, 1)
        XCTAssertEqual(report.finalSpeechResults, 1)
        XCTAssertTrue(report.checks.contains { $0.name == "speech_analyzer_duration_preserved" && $0.verdict == .pass })
    }

    @MainActor
    func testDeviceValidationMetricsFailWrongRawFormatAndTimelineGap() {
        let metrics = DeviceValidationMetricStore(startedAt: Date(timeIntervalSince1970: 0), startedUptime: 20)
        metrics.markSTTPrepared()
        metrics.markCaptureRequested(observedAt: 20)
        let wrongRaw = DeviceValidationAudioFormat(sampleRate: 44100, channels: 1, sampleFormat: "float32", interleaved: false)
        let processed = DeviceValidationAudioFormat(sampleRate: 48000, channels: 1, sampleFormat: "float32", interleaved: false)
        let analyzer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let analyzerBuffer = AVAudioPCMBuffer(pcmFormat: analyzer, frameCapacity: 32000)!
        analyzerBuffer.frameLength = 32000

        metrics.recordRaw(time: 0, frames: 44100, format: wrongRaw, observedAt: 20.1)
        metrics.recordRaw(time: 1.1, frames: 44100, format: wrongRaw, observedAt: 21.2)
        metrics.recordProcessed(time: 0, frames: 48000, format: processed)
        metrics.recordProcessed(time: 1.1, frames: 48000, format: processed)
        metrics.recordSpeechAppend(frames: 96000)
        metrics.recordAnalyzerInput(buffer: analyzerBuffer, startTime: .zero)
        metrics.recordPipelineMetrics(AudioMetrics(rmsDB: -20, peakDB: -4))

        let report = metrics.finish(userStopped: true, endedAt: Date(timeIntervalSince1970: 2.1), endedUptime: 22.1)
        XCTAssertEqual(report.verdict, .fail)
        XCTAssertEqual(report.rawGapCount, 1)
        XCTAssertTrue(report.checks.contains { $0.name == "raw_format_48k_stereo" && $0.verdict == .fail })
        XCTAssertTrue(report.checks.contains { $0.name == "raw_timeline_continuity" && $0.verdict == .fail })
    }

    @MainActor
    func testDeviceValidationScreenshotProbePassesContinuousAudioAcrossSameStreamScreenOutputWindow() {
        let metrics = DeviceValidationMetricStore(startedAt: Date(timeIntervalSince1970: 0), startedUptime: 10, requireScreenshotProbe: true)
        metrics.markSTTPrepared(); metrics.markCaptureRequested(observedAt: 10)
        let raw = DeviceValidationAudioFormat(sampleRate: 48000, channels: 2, sampleFormat: "float32", interleaved: false)
        let processed = DeviceValidationAudioFormat(sampleRate: 48000, channels: 1, sampleFormat: "float32", interleaved: false)
        let analyzer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let firstAnalyzer = AVAudioPCMBuffer(pcmFormat: analyzer, frameCapacity: 80000)!
        firstAnalyzer.frameLength = 80000
        let secondAnalyzer = AVAudioPCMBuffer(pcmFormat: analyzer, frameCapacity: 96000)!
        secondAnalyzer.frameLength = 96000

        metrics.recordRaw(time: 0, frames: 240000, format: raw, observedAt: 10.1)
        metrics.recordProcessed(time: 0, frames: 240000, format: processed)
        metrics.recordSpeechAppend(frames: 240000)
        metrics.recordAnalyzerInput(buffer: firstAnalyzer, startTime: .zero)
        metrics.markScreenshotProbeStarted(observedAt: 15)
        metrics.markScreenshotProbeFinished(metadata: ["mime":"image/webp", "width":1600, "height":900, "size_bytes":12345], observedAt: 15.8)

        metrics.recordRaw(time: 5, frames: 288000, format: raw, observedAt: 16)
        metrics.recordProcessed(time: 5, frames: 288000, format: processed)
        metrics.recordSpeechAppend(frames: 288000)
        metrics.recordAnalyzerInput(buffer: secondAnalyzer, startTime: CMTime(seconds: 5, preferredTimescale: 16000))
        metrics.recordPipelineMetrics(AudioMetrics(rmsDB: -18, peakDB: -3))
        metrics.recordSpeechResult(final: true, observedAt: 16.5)

        let report = metrics.finish(userStopped: true, endedAt: Date(timeIntervalSince1970: 11), endedUptime: 21)
        XCTAssertEqual(report.verdict, .pass)
        XCTAssertEqual(report.screenshotContinuity.verdict, .pass)
        XCTAssertTrue(report.screenshotContinuity.rawWindowCompleted)
        XCTAssertTrue(report.screenshotContinuity.processedWindowCompleted)
        XCTAssertTrue(report.screenshotContinuity.analyzerWindowCompleted)
        XCTAssertEqual(report.screenshotContinuity.rawGapCount, 0)
        XCTAssertEqual(report.screenshotContinuity.rawOverlapCount, 0)
        XCTAssertTrue(report.checks.contains { $0.name == "screenshot_audio_continuity" && $0.verdict == .pass })
    }

    @MainActor
    func testDeviceValidationScreenshotProbeFailsWhenGapAppearsAfterSameStreamScreenOutputStarts() {
        let metrics = DeviceValidationMetricStore(startedAt: Date(timeIntervalSince1970: 0), startedUptime: 10, requireScreenshotProbe: true)
        metrics.markSTTPrepared(); metrics.markCaptureRequested(observedAt: 10)
        let raw = DeviceValidationAudioFormat(sampleRate: 48000, channels: 2, sampleFormat: "float32", interleaved: false)
        let processed = DeviceValidationAudioFormat(sampleRate: 48000, channels: 1, sampleFormat: "float32", interleaved: false)
        let analyzer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let firstAnalyzer = AVAudioPCMBuffer(pcmFormat: analyzer, frameCapacity: 80000)!
        firstAnalyzer.frameLength = 80000
        let secondAnalyzer = AVAudioPCMBuffer(pcmFormat: analyzer, frameCapacity: 96000)!
        secondAnalyzer.frameLength = 96000

        metrics.recordRaw(time: 0, frames: 240000, format: raw, observedAt: 10.1)
        metrics.recordProcessed(time: 0, frames: 240000, format: processed)
        metrics.recordSpeechAppend(frames: 240000)
        metrics.recordAnalyzerInput(buffer: firstAnalyzer, startTime: .zero)
        metrics.markScreenshotProbeStarted(observedAt: 15)
        metrics.markScreenshotProbeFinished(metadata: ["mime":"image/webp", "width":1600, "height":900, "size_bytes":12345], observedAt: 15.8)

        metrics.recordRaw(time: 5.1, frames: 288000, format: raw, observedAt: 16)
        metrics.recordProcessed(time: 5.1, frames: 288000, format: processed)
        metrics.recordSpeechAppend(frames: 288000)
        metrics.recordAnalyzerInput(buffer: secondAnalyzer, startTime: CMTime(seconds: 5.1, preferredTimescale: 16000))
        metrics.recordPipelineMetrics(AudioMetrics(rmsDB: -18, peakDB: -3))
        metrics.recordSpeechResult(final: true, observedAt: 16.5)

        let report = metrics.finish(userStopped: true, endedAt: Date(timeIntervalSince1970: 11.1), endedUptime: 21.1)
        XCTAssertEqual(report.screenshotContinuity.verdict, .fail)
        XCTAssertGreaterThan(report.screenshotContinuity.rawGapCount, 0)
        XCTAssertTrue(report.checks.contains { $0.name == "screenshot_audio_continuity" && $0.verdict == .fail })
    }

    @MainActor
    func testDeviceValidationScreenshotFailurePreservesNSErrorDetail() {
        let metrics = DeviceValidationMetricStore(
            startedAt: Date(timeIntervalSince1970: 0),
            startedUptime: 10,
            requireScreenshotProbe: true)
        metrics.markScreenshotProbeStarted(observedAt: 15)
        let error = NSError(
            domain: "SCStreamErrorDomain",
            code: -3802,
            userInfo: [NSLocalizedDescriptionKey: "Screen output failed", "probe": "same-stream-screen-output"])
        metrics.markScreenshotProbeFailed(error, observedAt: 15.04)

        let report = metrics.finish(
            userStopped: true,
            endedAt: Date(timeIntervalSince1970: 6),
            endedUptime: 16)
        let screenshot = report.screenshotContinuity
        XCTAssertEqual(screenshot.verdict, .fail)
        XCTAssertTrue(screenshot.attempted)
        XCTAssertFalse(screenshot.succeeded)
        XCTAssertEqual(screenshot.errorDetail?.domain, "SCStreamErrorDomain")
        XCTAssertEqual(screenshot.errorDetail?.code, -3802)
        XCTAssertEqual(screenshot.errorDetail?.userInfo["probe"], "same-stream-screen-output")
    }

    @MainActor
    func testDeviceValidationRestartRequiresFreshZeroBasedTimelines() {
        func session(start: Double) -> DeviceValidationSessionReport {
            let metrics = DeviceValidationMetricStore(startedAt: Date(timeIntervalSince1970: 0), startedUptime: 30)
            metrics.markSTTPrepared(); metrics.markCaptureRequested(observedAt: 30)
            let raw = DeviceValidationAudioFormat(sampleRate: 48000, channels: 2, sampleFormat: "float32", interleaved: false)
            let processed = DeviceValidationAudioFormat(sampleRate: 48000, channels: 1, sampleFormat: "float32", interleaved: false)
            let analyzer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
            let analyzerBuffer = AVAudioPCMBuffer(pcmFormat: analyzer, frameCapacity: 160000)!
            analyzerBuffer.frameLength = 160000
            metrics.recordRaw(time: start, frames: 480000, format: raw, observedAt: 30.1)
            metrics.recordProcessed(time: start, frames: 480000, format: processed)
            metrics.recordSpeechAppend(frames: 480000)
            metrics.recordAnalyzerInput(buffer: analyzerBuffer, startTime: CMTime(seconds: start, preferredTimescale: 16000))
            metrics.recordPipelineMetrics(AudioMetrics(rmsDB: -18, peakDB: -3))
            metrics.recordSpeechResult(final: true, observedAt: 30.5)
            return metrics.finish(userStopped: true, endedAt: Date(timeIntervalSince1970: 10), endedUptime: 40)
        }

        let clean = DeviceValidationReport.make(sessions: [session(start: 0), session(start: 0)])
        XCTAssertEqual(clean.restartCheck.verdict, .pass)
        let stale = DeviceValidationReport.make(sessions: [session(start: 0), session(start: 10)])
        XCTAssertEqual(stale.restartCheck.verdict, .fail)
    }
    #endif
    #if PHASE2 && targetEnvironment(simulator)
    @MainActor
    func testSystemAudioInputFailsExplicitlyOnSimulator() async {
        do {
            _ = try await SystemAudioInput().start()
            XCTFail("Simulator system audio capture must not silently succeed.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Simulator"))
        }
    }
    #endif
    func testLearningResourcesDecodeInApplicationBundle() {
        XCTAssertFalse(LearningData.kanji.isEmpty, LearningData.resourceStatus.joined(separator: " · "))
        XCTAssertFalse(LearningData.deck.isEmpty, LearningData.resourceStatus.joined(separator: " · "))
    }
    func testUTF16SaveAfterEmoji() throws {
        let source = "🎮昨日のゲーム"
        let row = Caption(captureID: UUID(), language: .japanese, source: source, start: 0, end: 2, isFinal: true)
        let token = WordToken(surface: "昨日", lemma: "昨日", reading: "きのう", start: 2, end: 4)
        let session = LearningSession(id: "s", title: nil, raw_url: nil, session_key: nil)
        let payload = try SavePayload.make(caption: row, session: session, token: token, tokens: [token], translation: "어제")
        XCTAssertEqual(payload["target_start_index"] as? Int, 2)
        XCTAssertNil(payload["screenshot"])
        XCTAssertEqual(payload["context_group_id"] as? String, row.contextGroup)
    }
    func testWrongRangeRejected() {
        let row = Caption(captureID: UUID(), language: .japanese, source: "🎮昨日", start: 0, end: 2, isFinal: true)
        let token = WordToken(surface: "昨日", lemma: "昨日", start: 1, end: 3)
        XCTAssertThrowsError(try SavePayload.make(caption: row,
            session: .init(id: "s", title: nil, raw_url: nil, session_key: nil), token: token, tokens: [token], translation: ""))
    }
    func testUniqueContextAcrossRepeatedBroadcastText() {
        let a = Caption(captureID: UUID(), language: .japanese, source: "ありがとう", start: 0, end: 1, isFinal: true)
        let b = Caption(captureID: UUID(), language: .japanese, source: "ありがとう", start: 0, end: 1, isFinal: true)
        XCTAssertNotEqual(a.contextGroup, b.contextGroup)
    }
    func testNaturalLanguageSentenceBoundaryDoesNotUseShortPauseRules() {
        XCTAssertNil(SentenceBoundary.firstCompletedSentencePrefixUTF16Length(in: "そうだけど", language: .japanese))
        XCTAssertNotNil(SentenceBoundary.firstCompletedSentencePrefixUTF16Length(in: "そうです。", language: .japanese))
        XCTAssertEqual(SentenceBoundary.fallbackSilence, 2.0)
        XCTAssertEqual(SentenceBoundary.fallbackDuration, 20.0)
    }
    func testNoSpeechNoBoostAndFiniteCeiling() {
        var leveler = SpeechLeveler()
        let quiet = [Float](repeating: 0.01, count: 4800)
        XCTAssertEqual(leveler.process(quiet, speechProbability: nil), quiet)
        let loud = leveler.process([Float](repeating: 3, count: 4800), speechProbability: 1)
        XCTAssertTrue(loud.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
    }
    func testAntiphaseNotCancelled() {
        let left: [Float] = [0.1, -0.1, 0.1, -0.1]
        let right = left.map { -$0 }
        XCTAssertEqual(StereoSelection.mono(left: left, right: right), left)
    }
    func testThreeSpeakersNeverSeparated() {
        var gate = OverlapGate()
        XCTAssertFalse(gate.observe(activeSpeakers: 2, probability: 0.9))
        XCTAssertFalse(gate.observe(activeSpeakers: 2, probability: 0.9))
        XCTAssertTrue(gate.observe(activeSpeakers: 2, probability: 0.9))
        XCTAssertFalse(gate.observe(activeSpeakers: 3, probability: 0.9))
        XCTAssertFalse(gate.observe(activeSpeakers: nil, probability: 0.9))
    }

    func testDefensiveOverlappingFinalCannotDuplicateStableText() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日はも", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.receive("今日は晴れも", final: true, start: 0, end: 2, speaker: nil, now: 1)
        XCTAssertEqual(buffer.rows.map(\.source), ["今日は晴れも"])
        XCTAssertEqual(buffer.rows.count, 1)
        XCTAssertFalse(buffer.rows[0].isFinal)
    }

    func testPartialOverlappingFinalCannotDuplicateOrSurgicallyRewriteStableText() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日は", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.receive("は晴れ", final: true, start: 0.5, end: 1.5, speaker: nil, now: 1)
        XCTAssertEqual(buffer.rows.map(\.source), ["今日は"])
    }

    func testLateOverlappingFinalCannotResurrectCommittedHistory() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日は晴れ。", final: true, start: 0, end: 1, speaker: nil, now: 0)
        XCTAssertTrue(buffer.rows[0].isFinal)
        _ = buffer.receive("今日は雨。次です。", final: true, start: 0, end: 2, speaker: nil, now: 1)
        XCTAssertEqual(buffer.rows.map(\.source), ["今日は晴れ。"])
    }

    func testQualityLexicalConflictKeepsPrimary() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        _ = buffer.receive("今日は晴れです。", final: true, start: 0, end: 1, speaker: nil, now: 0)
        let quality = Caption(captureID: capture, language: .japanese,
                              source: "今日は雨です。", start: 0, end: 1, isFinal: true)
        if case .rejected = buffer.resolveRevision(quality) {} else { XCTFail("lexical conflict must keep primary") }
        XCTAssertEqual(buffer.rows[0].source, "今日は晴れです。")
    }

    func testQualityPunctuationConflictStillKeepsPrimary() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        _ = buffer.receive("今日は晴れです。", final: true, start: 0, end: 1, speaker: nil, now: 0)
        let quality = Caption(captureID: capture, language: .japanese,
                              source: "今日は晴れです！", start: 0, end: 1, isFinal: true)
        if case .rejected = buffer.resolveRevision(quality) {} else { XCTFail("Primary punctuation must win") }
        XCTAssertEqual(buffer.rows[0].source, "今日は晴れです。")
    }

    func testQualityPunctuationHeuristicCannotChangeEnglishMeaning() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .english)
        _ = buffer.receive("well.", final: true, start: 0, end: 1, speaker: nil, now: 0)
        let quality = Caption(captureID: capture, language: .english,
                              source: "we'll.", start: 0, end: 1, isFinal: true)
        if case .rejected = buffer.resolveRevision(quality) {} else { XCTFail("Primary text must win") }
        XCTAssertEqual(buffer.rows[0].source, "well.")
    }

    func testFinalizationFrontierPromotesUnchangedVolatileWithoutReissue() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日は", final: false, start: 0, end: 1, speaker: nil, now: 0, finalizedThrough: 0)
        XCTAssertEqual(buffer.rows.map(\.source), ["今日は"])
        // Apple may finalize the previous volatile result without re-emitting that same
        // text. A later range advancing the frontier must preserve, not delete, it.
        _ = buffer.receive("晴れ", final: false, start: 1, end: 1.5, speaker: nil, now: 0.1, finalizedThrough: 1)
        XCTAssertEqual(buffer.rows.map(\.source), ["今日は晴れ"])
    }

    func testFinalizationPromotionCanCommitCompletedSentence() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日は晴れ。", final: false, start: 0, end: 1, speaker: nil, now: 0, finalizedThrough: 0)
        let ready = buffer.receive("次です", final: false, start: 1, end: 1.6, speaker: nil, now: 0.1, finalizedThrough: 1)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(buffer.rows.map(\.source), ["今日は晴れ。", "次です"])
        XCTAssertTrue(buffer.rows[0].isFinal)
        XCTAssertFalse(buffer.rows[1].isFinal)
    }

    func testEmptyVolatileResultRevokesMatchingTentativeText() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("も", final: false, start: 0, end: 0.3, speaker: nil, now: 0, finalizedThrough: 0)
        XCTAssertEqual(buffer.rows.map(\.source), ["も"])
        _ = buffer.receive("", final: false, start: 0, end: 0.3, speaker: nil, now: 0.1, finalizedThrough: 0)
        XCTAssertTrue(buffer.rows.isEmpty)
    }

    func testFinalizationFrontierDoesNotPrematurelyPromoteLiveVolatileTail() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日は", final: true, start: 0, end: 1, speaker: nil, now: 0, finalizedThrough: 1)
        _ = buffer.receive("も", final: false, start: 1, end: 1.3, speaker: nil, now: 0.1, finalizedThrough: 1.1)
        XCTAssertEqual(buffer.rows.map(\.source), ["今日はも"])
        XCTAssertFalse(buffer.rows[0].isFinal)
    }

    func testStableRowIdentityFromVolatileToFinal() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        XCTAssertTrue(buffer.receive("今日は", final: false, start: 0, end: 1, speaker: nil, now: 0).isEmpty)
        let draftID = buffer.rows[0].id
        let ready = buffer.receive("今日は晴れです。", final: true, start: 0, end: 2, speaker: nil, now: 1)
        XCTAssertEqual(ready, [draftID])
        XCTAssertEqual(buffer.rows.count, 1)
        XCTAssertEqual(buffer.rows[0].id, draftID)
        XCTAssertTrue(buffer.rows[0].isFinal)
    }
    func testFinalPrefixRemainsVisibleAndTailSurvivesCommit() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("昨日", final: true, start: 0, end: 1, speaker: nil, now: 0)
        XCTAssertEqual(buffer.rows.map(\.source), ["昨日"])
        let firstID = buffer.rows[0].id
        _ = buffer.receive("ゲーム", final: false, start: 1, end: 2, speaker: nil, now: 0.5)
        XCTAssertTrue(buffer.tick(now: 1.3).isEmpty)
        XCTAssertEqual(buffer.tick(now: 2.6, activity: AudioActivity(through: 3.6, speaking: false, silence: 2.6)), [firstID])
        XCTAssertEqual(buffer.rows.map(\.source), ["昨日", "ゲーム"])
        let tailID = buffer.rows[1].id
        _ = buffer.receive("ゲームをした。", final: true, start: 1, end: 3, speaker: nil, now: 3)
        XCTAssertEqual(buffer.rows.map(\.id), [firstID, tailID])
        XCTAssertEqual(buffer.rows.map(\.source), ["昨日", "ゲームをした。"])
    }
    func testNewCapturePreservesHistoryAndDoesNotReuseContext() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("はい。", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.tick(now: 0.31)
        _ = buffer.finish()
        let group = buffer.rows[0].contextGroup
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("はい。", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.tick(now: 0.31)
        XCTAssertEqual(buffer.rows.count, 2)
        XCTAssertNotEqual(buffer.rows[1].contextGroup, group)
    }
    func testDraftJapaneseCanBeSavedButEnglishCannot() throws {
        let session = LearningSession(id: "s", title: nil, raw_url: nil, session_key: nil)
        let draft = Caption(captureID: UUID(), language: .japanese, source: "途中", start: 0, end: 1, isFinal: false)
        XCTAssertNoThrow(try SavePayload.make(caption: draft, session: session, token: nil, tokens: [], translation: "도중"))
        let english = Caption(captureID: UUID(), language: .english, source: "test", start: 0, end: 1, isFinal: true)
        XCTAssertThrowsError(try SavePayload.make(caption: english, session: session, token: nil, tokens: [], translation: ""))
    }
    func testLearningScreenshotPayloadIsForwarded() throws {
        let row = Caption(captureID: UUID(), language: .japanese, source: "保存", start: 0, end: 1, isFinal: false)
        let session = LearningSession(id: "s", title: nil, raw_url: nil, session_key: nil)
        let screenshot: [String: Any] = ["base64":"YWJj", "mime":"image/webp", "width":1600, "height":900, "size_bytes":3, "downscaled":true]
        let payload = try SavePayload.make(caption: row, session: session, token: nil, tokens: [], translation: "저장", screenshot: screenshot)
        let saved = payload["screenshot"] as? [String: Any]
        XCTAssertEqual(saved?["mime"] as? String, "image/webp")
        XCTAssertEqual(saved?["width"] as? Int, 1600)
    }
    func testAIReadingNormalizationUsesHiragana() {
        XCTAssertEqual(JapaneseText.hiragana("カタカナ・ABC"), "かたかな・ABC")
    }
    func testEnglishChunkJoiningDoesNotDoubleWhitespace() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .english)
        _ = buffer.receive("Hello ", final: true, start: 0, end: 0.5, speaker: nil, now: 0)
        _ = buffer.receive("world.", final: true, start: 0.5, end: 1, speaker: nil, now: 0.5)
        XCTAssertEqual(buffer.rows[0].source, "Hello world.")
    }
    func testUnfinalizedTailIsMarkedOnStop() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("途中", final: false, start: 0, end: 1, speaker: nil, now: 0)
        XCTAssertTrue(buffer.finish().isEmpty)
        XCTAssertFalse(buffer.rows[0].isFinal)
        XCTAssertNotNil(buffer.rows[0].translationError)
    }
    func testSpeakerDecisionsOnlyCoverTheirOwnAudioInterval() {
        var timeline = SpeechTimeline()
        timeline.append([SpeechDecision(speechProbability: 1, activeSpeakers: 1, start: 10, end: 10.1, speakerSlot: 2)])
        XCTAssertEqual(timeline.speaker(start: 10.01, end: 10.09), 2)
        XCTAssertNil(timeline.decision(start: 10.9, end: 11))
        XCTAssertNil(timeline.decision(start: 9.9, end: 10))
        XCTAssertNil(timeline.decision(start: 10.05, end: 10.15))
    }
    func testEnhancementFailureRestoresBufferedDryAudio() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.setProviders(analysis: PatternAnalysis(), enhancement: FailingEnhancer())
        let (first, _) = try await pipeline.process(Self.pcm(count: 480, time: 0, amplitude: 0.2))
        let (second, _) = try await pipeline.process(Self.pcm(count: 480, time: 0.01, amplitude: 0.2))
        let recovered = first + second + (try await pipeline.finish())
        XCTAssertEqual(recovered.reduce(0) { $0+Int($1.buffer.frameLength) }, 960)
        XCTAssertEqual(recovered.first?.time, 0)
        XCTAssertTrue(Self.samples(recovered).allSatisfy { abs($0-0.2) < 0.0001 })
    }
    func testRawInputRetainsTimestampGaps() async throws {
        let pipeline = AudioPreprocessor()
        _ = try await pipeline.process(Self.pcm(count: 480, time: 0))
        let (later, _) = try await pipeline.process(Self.pcm(count: 480, time: 5))
        XCTAssertEqual(later[0].time, 5)
    }
    func testTranslationQueuesRemainSeparateAcrossLanguageChanges() {
        var backlog = TranslationBacklog()
        let japanese = [UUID(), UUID()]
        let english = UUID()
        backlog.enqueue(japanese, language: .japanese)
        XCTAssertNil(backlog.take(language: .english))
        backlog.enqueue([english], language: .english)
        XCTAssertEqual(backlog.take(language: .english), english)
        XCTAssertEqual(backlog.pending(language: .japanese), japanese)
        XCTAssertEqual(backlog.take(language: .japanese), japanese[0])
        XCTAssertEqual(backlog.take(language: .japanese), japanese[1])
        XCTAssertNil(backlog.take(language: .japanese))
    }
    func testCancelledTranslationIsRestoredBeforeRemainingJobs() {
        var backlog = TranslationBacklog()
        let first = UUID(), next = UUID()
        backlog.enqueue([first, next], language: .japanese)
        XCTAssertEqual(backlog.take(language: .japanese), first)
        backlog.restore(first, language: .japanese)
        XCTAssertEqual(backlog.pending(language: .japanese), [first, next])
        XCTAssertTrue(backlog.pending(language: .english).isEmpty)
    }
    func testEmptyResultRevokesTentativeOnlyRow() {
        for final in [false, true] {
            var buffer = TranscriptBuffer()
            buffer.begin(captureID: UUID(), language: .japanese)
            _ = buffer.receive("誤認識", final: false, start: 0, end: 1, speaker: 0, now: 0)
            XCTAssertEqual(buffer.rows.count, 1)
            XCTAssertTrue(buffer.receive("", final: final, start: 0, end: 1, speaker: nil, now: 1).isEmpty)
            XCTAssertTrue(buffer.rows.isEmpty)
            XCTAssertTrue(buffer.receive("", final: final, start: 0, end: 1, speaker: nil, now: 2).isEmpty)
            XCTAssertTrue(buffer.tick(now: 3).isEmpty)
            XCTAssertTrue(buffer.finish().isEmpty)
            XCTAssertTrue(buffer.rows.isEmpty)
        }
    }
    func testPunctuationOnlyRecognizerResultNeverCreatesStandaloneCaption() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        XCTAssertTrue(buffer.receive(".", final: true, start: 0, end: 0.1, speaker: nil, now: 0).isEmpty)
        XCTAssertTrue(buffer.rows.isEmpty)
        _ = buffer.receive("今日は", final: true, start: 0.2, end: 1, speaker: nil, now: 0.2)
        let ready = buffer.receive("。", final: true, start: 1, end: 1.01, speaker: nil, now: 0.3)
        XCTAssertEqual(buffer.rows.map(\.source), ["今日は。"] )
        XCTAssertEqual(ready.count, 1)
        XCTAssertTrue(buffer.rows[0].isFinal)
    }

    func testRevocationPreservesFinalPrefixIdentityAndTiming() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("昨日", final: true, start: 0, end: 1, speaker: 0, now: 0)
        let id = buffer.rows[0].id
        let group = buffer.rows[0].contextGroup
        _ = buffer.receive("誤認識", final: false, start: 1, end: 2, speaker: 1, now: 0.5)
        let revision = buffer.rows[0].revision
        XCTAssertTrue(buffer.receive("", final: false, start: 1, end: 2, speaker: nil, now: 1).isEmpty)
        XCTAssertEqual(buffer.rows.map(\.source), ["昨日"])
        XCTAssertEqual(buffer.rows[0].id, id)
        XCTAssertEqual(buffer.rows[0].contextGroup, group)
        XCTAssertGreaterThan(buffer.rows[0].revision, revision)
        XCTAssertEqual(buffer.rows[0].start, 0)
        XCTAssertEqual(buffer.rows[0].end, 1)
        XCTAssertEqual(buffer.rows[0].speaker, 0)
        XCTAssertEqual(buffer.tick(now: 3.6), [id])
        XCTAssertTrue(buffer.rows[0].isFinal)
    }
    func testRevocationDoesNotRemoveCommittedHistory() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("はい。", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.tick(now: 0.31)
        buffer.rows[0].translation = "네."
        let id = buffer.rows[0].id
        _ = buffer.receive("誤認識", final: false, start: 1, end: 2, speaker: nil, now: 0.5)
        _ = buffer.receive("", final: true, start: 1, end: 2, speaker: nil, now: 1)
        XCTAssertEqual(buffer.rows.map(\.id), [id])
        XCTAssertEqual(buffer.rows[0].source, "はい。")
        XCTAssertEqual(buffer.rows[0].translation, "네.")
        XCTAssertTrue(buffer.rows[0].isFinal)
    }
    func testUnrelatedOrInvalidEmptyRangeDoesNotRevokeCurrentPhrase() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .english)
        _ = buffer.receive("hello", final: false, start: 2, end: 3, speaker: nil, now: 0)
        let id = buffer.rows[0].id
        for (start, end) in [(0.0, 2.0), (3.0, 4.0), (Double.nan, 3.0), (2.0, Double.infinity), (3.0, 2.0)] {
            _ = buffer.receive("", final: false, start: start, end: end, speaker: nil, now: 1)
            XCTAssertEqual(buffer.rows.map(\.id), [id])
            XCTAssertEqual(buffer.rows[0].source, "hello")
        }
    }
    func testNewPhraseAfterRevocationDoesNotReuseDiscardedContext() {
        var buffer = TranscriptBuffer()
        let captureID = UUID()
        buffer.begin(captureID: captureID, language: .english)
        _ = buffer.receive("noise", final: false, start: 0, end: 1, speaker: nil, now: 0)
        let discardedGroup = buffer.rows[0].contextGroup
        _ = buffer.receive("", final: false, start: 0, end: 1.1, speaker: nil, now: 1)
        let ready = buffer.receive("Hello.", final: true, start: 2, end: 3, speaker: nil, now: 2)
        XCTAssertEqual(buffer.rows.count, 1)
        XCTAssertEqual(ready, [buffer.rows[0].id])
        XCTAssertEqual(buffer.rows[0].source, "Hello.")
        XCTAssertEqual(buffer.rows[0].captureID, captureID)
        XCTAssertNotEqual(buffer.rows[0].contextGroup, discardedGroup)
    }
    func testTranslationFailureRetriesHaveDelaysAndStop() {
        var backlog = TranslationBacklog()
        let id = UUID()
        backlog.enqueue([id], language: .japanese)
        XCTAssertEqual(backlog.take(language: .japanese, now: 0), id)
        XCTAssertTrue(backlog.failed(id, language: .japanese, now: 0))
        XCTAssertNil(backlog.take(language: .japanese, now: 0.99))
        XCTAssertEqual(backlog.take(language: .japanese, now: 1), id)
        XCTAssertTrue(backlog.failed(id, language: .japanese, now: 1))
        XCTAssertNil(backlog.take(language: .japanese, now: 3.99))
        XCTAssertEqual(backlog.take(language: .japanese, now: 4), id)
        XCTAssertFalse(backlog.failed(id, language: .japanese, now: 4))
        XCTAssertNil(backlog.take(language: .japanese, now: 100))
        XCTAssertEqual(backlog.failedIDs(language: .japanese), [id])
    }
    func testDelayedTranslationDoesNotBlockNextRowOrOtherLanguage() {
        var backlog = TranslationBacklog()
        let failed = UUID(), next = UUID(), english = UUID()
        backlog.enqueue([failed, next], language: .japanese)
        backlog.enqueue([english], language: .english)
        XCTAssertEqual(backlog.take(language: .japanese, now: 0), failed)
        _ = backlog.failed(failed, language: .japanese, now: 0)
        XCTAssertEqual(backlog.take(language: .japanese, now: 0), next)
        XCTAssertEqual(backlog.take(language: .english, now: 0), english)
    }
    func testManualTranslationRetryStartsOneNewBoundedCycle() {
        var backlog = TranslationBacklog()
        let id = UUID()
        backlog.enqueue([id, id], language: .english)
        for time in [0.0, 1.0, 4.0] {
            XCTAssertEqual(backlog.take(language: .english, now: time), id)
            _ = backlog.failed(id, language: .english, now: time)
        }
        XCTAssertTrue(backlog.retryFailed(language: .japanese).isEmpty)
        XCTAssertEqual(backlog.retryFailed(language: .english), [id])
        XCTAssertTrue(backlog.retryFailed(language: .english).isEmpty)
        XCTAssertEqual(backlog.take(language: .english, now: 5), id)
        backlog.enqueue([id], language: .english)
        XCTAssertNil(backlog.take(language: .english, now: 5))
        XCTAssertTrue(backlog.failed(id, language: .english, now: 5))
    }
    func testTranslationCancellationDoesNotSpendFailureBudget() {
        var backlog = TranslationBacklog()
        let id = UUID(); backlog.enqueue([id], language: .japanese)
        for _ in 0..<5 {
            XCTAssertEqual(backlog.take(language: .japanese, now: 0), id)
            backlog.restore(id, language: .japanese)
        }
        XCTAssertEqual(backlog.take(language: .japanese, now: 0), id)
        XCTAssertTrue(backlog.failed(id, language: .japanese, now: 0))
        XCTAssertEqual(backlog.take(language: .japanese, now: 1), id)
        backlog.complete(id)
        XCTAssertTrue(backlog.failedIDs(language: .japanese).isEmpty)
        XCTAssertNil(backlog.take(language: .japanese, now: 100))
    }
    func testContinuousVolatileUpdatesDoNotBecomeAPause() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日は", final: true, start: 0, end: 1, speaker: nil, now: 0)
        for time in [1.0, 2.0, 3.0] {
            _ = buffer.receive("まだ話しています", final: false, start: 1, end: time+1, speaker: nil, now: time)
            XCTAssertTrue(buffer.tick(now: time+0.5).isEmpty)
            XCTAssertEqual(buffer.rows.count, 1)
            XCTAssertFalse(buffer.rows[0].isFinal)
        }
    }
    func testMatchedOngoingSpeechVetoesRecognizerIdleCommit() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日は", final: true, start: 0, end: 1, speaker: nil, now: 0)
        XCTAssertTrue(buffer.tick(now: 5, activity: AudioActivity(through: 5, speaking: true, silence: 0)).isEmpty)
        XCTAssertFalse(buffer.rows[0].isFinal)
    }
    func testShortBreathNeverCommitsButLongSilenceFallbackDoes() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("そうだけど", final: true, start: 0, end: 1, speaker: nil, now: 0)
        XCTAssertTrue(buffer.tick(now: 1.5, activity: AudioActivity(through: 1.7, speaking: false, silence: 0.7)).isEmpty)
        XCTAssertEqual(buffer.tick(now: 2.5, activity: AudioActivity(through: 3.2, speaking: false, silence: 2.2)).count, 1)
    }
    func testLongDurationFallbackCommitsOnlyStablePrefixAndKeepsVolatileTail() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("前半", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.receive("続く話", final: false, start: 1, end: 21, speaker: nil, now: 21)
        XCTAssertEqual(buffer.tick(now: 21, activity: AudioActivity(through: 21, speaking: true, silence: 0)).count, 1)
        XCTAssertEqual(buffer.rows.map(\.source), ["前半", "続く話"])
        XCTAssertTrue(buffer.rows[0].isFinal)
        XCTAssertFalse(buffer.rows[1].isFinal)
    }
    func testSpeakerChangeDoesNotDefineSentenceBoundary() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("昨日", final: true, start: 0, end: 1, speaker: 0, now: 0)
        XCTAssertTrue(buffer.receive("ゲーム", final: true, start: 1, end: 2, speaker: 1, now: 0.1).isEmpty)
        XCTAssertEqual(buffer.rows.count, 1)
        XCTAssertFalse(buffer.rows[0].isFinal)
        XCTAssertEqual(buffer.rows[0].source, "昨日ゲーム")
    }
    func testSustainedSpeakerTurnStillDoesNotOverrideSentenceTokenizer() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("昨日", final: true, start: 0, end: 1, speaker: 0, now: 0)
        XCTAssertTrue(buffer.receive("ゲーム", final: true, start: 1, end: 1.4, speaker: 1, now: 0.1).isEmpty)
        XCTAssertEqual(buffer.rows.count, 1)
        XCTAssertFalse(buffer.rows[0].isFinal)
    }
    func testQualityRevisionCannotMergePrimaryRowsUntilConsensusResolverExists() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        _ = buffer.receive("これはテストです。", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.receive("次です。", final: true, start: 1, end: 2, speaker: nil, now: 1)
        XCTAssertEqual(buffer.rows.count, 2)
        let originalIDs = buffer.rows.map(\.id)
        let revised = Caption(captureID: capture, language: .japanese,
            source: "これはテストです。次です。", start: 0, end: 2, isFinal: true)
        XCTAssertNil(buffer.applyRevision(revised))
        XCTAssertEqual(buffer.rows.count, 2)
        XCTAssertEqual(buffer.rows.map(\.source), ["これはテストです。", "次です。"])
        XCTAssertEqual(buffer.rows.map(\.id), originalIDs)
    }

    func testLateSpeakerTimelineUpdatesVisibleCaptionWithoutHoldingSTT() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("昨日ゲームをした", final: true, start: 0, end: 1, speaker: nil, now: 0)
        var timeline = SpeechTimeline()
        timeline.append([SpeechDecision(speechProbability: 1, activeSpeakers: 1, start: 0, end: 1, speakerSlot: 2)])
        let changed = buffer.applySpeakerTimeline(timeline)
        XCTAssertEqual(changed, [buffer.rows[0].id])
        XCTAssertEqual(buffer.rows[0].speaker, 2)
    }

    func testPartialQualityRevisionCannotEraseTheRestOfALongerCaption() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        _ = buffer.receive("昨日から今日までずっと勉強していました。", final: true,
                           start: 0, end: 10, speaker: nil, now: 10)
        let original = buffer.rows[0]
        let short = Caption(captureID: capture, language: .japanese,
                            source: "今日まで。", start: 4, end: 5, isFinal: true)
        XCTAssertNil(buffer.applyRevision(short))
        XCTAssertEqual(buffer.rows.count, 1)
        XCTAssertEqual(buffer.rows[0].source, original.source)
        XCTAssertEqual(buffer.rows[0].id, original.id)
    }

    func testQualityRevisionDoesNotInventCoverageOutsideExistingRowsOrAcrossAGap() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        _ = buffer.receive("最初です。", final: true, start: 0, end: 1, speaker: nil, now: 1)
        let larger = Caption(captureID: capture, language: .japanese,
                             source: "最初から最後です。", start: 0, end: 3, isFinal: true)
        XCTAssertNil(buffer.applyRevision(larger))
        _ = buffer.receive("最後です。", final: true, start: 2, end: 3, speaker: nil, now: 3)
        XCTAssertNil(buffer.applyRevision(larger))
        XCTAssertEqual(buffer.rows.count, 2)
    }

    func testQualityRevisionRejectsNonfiniteTime() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        _ = buffer.receive("元の文章。", final: true, start: 0, end: 1, speaker: nil, now: 1)
        for end in [Double.infinity, Double.nan] {
            XCTAssertNil(buffer.applyRevision(Caption(captureID: capture, language: .japanese,
                source: "違う文章。", start: 0, end: end, isFinal: true)))
        }
        XCTAssertEqual(buffer.rows[0].source, "元の文章。")
    }

    func testClearRejectsDelayedAndCrossingPhrasesThenResumesAndNewCaptureResetsTime() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.clearDisplay(through: 5)
        _ = buffer.receive("古い仮説", final: false, start: 1, end: 4, speaker: nil, now: 6)
        _ = buffer.receive("境界をまたぐ文章。", final: true, start: 4, end: 6, speaker: nil, now: 7)
        XCTAssertTrue(buffer.rows.isEmpty)
        _ = buffer.receive("新しい文章。", final: true, start: 6, end: 7, speaker: nil, now: 8)
        XCTAssertEqual(buffer.rows.map(\.source), ["新しい文章。"])
        let next = UUID()
        buffer.begin(captureID: next, language: .japanese)
        _ = buffer.receive("次の録音。", final: true, start: 0, end: 1, speaker: nil, now: 9)
        XCTAssertEqual(buffer.rows.last?.captureID, next)
        XCTAssertEqual(buffer.rows.last?.source, "次の録音。")
    }

    func testSpeakerTimelineDoesNotRelabelPreviousCaptureAtSameAudioTime() {
        let previous = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: previous, language: .japanese)
        _ = buffer.receive("前回です。", final: true, start: 0, end: 1, speaker: 1, now: 1)
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今回です。", final: true, start: 0, end: 1, speaker: nil, now: 2)
        var timeline = SpeechTimeline()
        timeline.append([SpeechDecision(speechProbability: 1, activeSpeakers: 1,
                                       start: 0, end: 1, speakerSlot: 2)])
        _ = buffer.applySpeakerTimeline(timeline)
        XCTAssertEqual(buffer.rows[0].speaker, 1)
        XCTAssertEqual(buffer.rows[1].speaker, 2)
    }

    func testQualityBacklogBoundsAudioIncludingInFlightWork() {
        var budget = QualityAudioBudget()
        XCTAssertTrue(budget.reserve(duration: 2))
        XCTAssertTrue(budget.reserve(duration: 1))
        XCTAssertFalse(budget.reserve(duration: 0.01))
        XCTAssertEqual(budget.count, 2)
        budget.release(duration: 2)
        XCTAssertTrue(budget.reserve(duration: 1))
        XCTAssertFalse(budget.reserve(duration: .nan))
        XCTAssertFalse(budget.reserve(duration: -.infinity))
        XCTAssertFalse(budget.reserve(duration: 0))
    }

    func testQualityBacklogAlsoBoundsTinyBuffers() {
        var budget = QualityAudioBudget()
        for _ in 0..<256 { XCTAssertTrue(budget.reserve(duration: 1.0/48000)) }
        XCTAssertFalse(budget.reserve(duration: 1.0/48000))
        budget.release(duration: 1.0/48000)
        XCTAssertTrue(budget.reserve(duration: 1.0/48000))
    }

    @MainActor
    func testStoppingQualityPreparationDoesNotWaitForLoaderOrDeliverLateResults() async {
        let sink = TestQualitySpeechSink(holdPreparation: true)
        let setup = OptionalProviderPreparation()
        await setup.start(analysis: nil, enhancement: nil)
        var resultCount = 0
        let pass = QualitySpeechPass(pipeline: AudioPreprocessor(analysisPolicy: .qualityRevision),
            language: .japanese, speech: sink, optional: setup,
            result: { _, _, _, _, _ in resultCount += 1 }, output: { _ in }, status: { _ in })
        pass.offer(Self.pcm(count: 4800, time: 0))
        await sink.waitUntilPreparationStarted()
        for index in 1...100 { pass.offer(Self.pcm(count: 4800, time: Double(index)/10)) }
        XCTAssertEqual(pass.diagnostics.backlog, 0)
        XCTAssertEqual(pass.diagnostics.skippedChunks, 101)
        // Deliberately leave preparation suspended: Stop must return before release.
        await pass.finish(aborting: true)
        sink.emitResult()
        XCTAssertEqual(resultCount, 0)
        sink.releasePreparation()
        await pass.finish(aborting: false)
        XCTAssertEqual(sink.appendCount, 0)
        XCTAssertTrue(sink.abortCount > 0)
    }

    @MainActor
    func testQualityQueueOverflowDisablesOnlyThatPassAndRejectsLateDelivery() async {
        let sink = TestQualitySpeechSink(holdPreparation: false)
        let setup = OptionalProviderPreparation()
        await setup.start(analysis: nil, enhancement: nil)
        var resultCount = 0, lastStatus = ""
        let pass = QualitySpeechPass(pipeline: AudioPreprocessor(analysisPolicy: .qualityRevision),
            language: .japanese, speech: sink, optional: setup,
            result: { _, _, _, _, _ in resultCount += 1 }, output: { _ in }, status: { lastStatus = $0 })
        pass.offer(Self.pcm(count: 4800, time: 0))
        await sink.waitUntilPreparationStarted()
        for _ in 0..<100 {
            if pass.acceptingInput { break }
            await Task.yield()
        }
        XCTAssertTrue(pass.acceptingInput)
        // Simulate a producer burst while the optional worker cannot consume.
        for index in 1...40 { pass.offer(Self.pcm(count: 4800, time: Double(index)/10)) }
        XCTAssertFalse(pass.acceptingInput)
        XCTAssertEqual(pass.diagnostics.overloadStops, 1)
        XCTAssertLessThanOrEqual(pass.diagnostics.peakBacklog, 3)
        XCTAssertTrue(lastStatus.contains("빠른 STT 유지"))
        sink.emitResult()
        XCTAssertEqual(resultCount, 0)
        await pass.finish(aborting: false)
        XCTAssertTrue(sink.abortCount > 0)
    }

    func testLiveInputBacklogCountsInFlightAudioAndReturnsToZero() {
        let progress = AudioInputProgress()
        let first = Self.pcm(count: 4800, time: 7)
        let second = Self.pcm(count: 4800, time: 7.1)
        _ = progress.captured(first); _ = progress.captured(second)
        XCTAssertEqual(progress.snapshot().pendingAudio, 0.2, accuracy: 0.000001)
        XCTAssertEqual(progress.snapshot().sourceBacklog, 0.2, accuracy: 0.000001)
        progress.processed(first)
        XCTAssertEqual(progress.snapshot().pendingChunks, 1)
        XCTAssertEqual(progress.snapshot().pendingAudio, 0.1, accuracy: 0.000001)
        progress.processed(second)
        XCTAssertEqual(progress.snapshot().pendingChunks, 0)
        XCTAssertEqual(progress.snapshot().sourceBacklog, 0, accuracy: 0.000001)
        XCTAssertEqual(progress.snapshot().pendingAudio, 0, accuracy: 0.000001)
        XCTAssertEqual(progress.snapshot().peakPendingAudio, 0.2, accuracy: 0.000001)
    }

    func testRealSourceGapIsNotCountedAsQueuedPCM() {
        let progress = AudioInputProgress()
        let first = Self.pcm(count: 4800, time: 0)
        let afterGap = Self.pcm(count: 4800, time: 30)
        _ = progress.captured(first); progress.processed(first)
        _ = progress.captured(afterGap)
        XCTAssertEqual(progress.snapshot().pendingAudio, 0.1, accuracy: 0.000001)
        XCTAssertGreaterThan(progress.snapshot().sourceBacklog, 29)
        progress.processed(afterGap)
        XCTAssertEqual(progress.snapshot().sourceBacklog, 0, accuracy: 0.000001)
    }

    func testRetainedTimelineLookupStillRejectsGapsAndKeepsSpeakerOrder() {
        var timeline = SpeechTimeline()
        for index in 0..<1000 {
            timeline.append([.init(speechProbability: 1, activeSpeakers: 1,
                                  start: Double(index), end: Double(index)+0.9, speakerSlot: index%2)])
        }
        XCTAssertLessThan(timeline.frames.count, 123)
        XCTAssertEqual(timeline.speaker(start: 998, end: 998.5), 0)
        XCTAssertEqual(timeline.speaker(start: 999, end: 999.5), 1)
        XCTAssertNil(timeline.covering(start: 998.8, end: 999.1))
        XCTAssertNil(timeline.covering(start: 1, end: 1.5))
    }

    func testClearDisplayResetsVisibleChunkWithoutEndingCapture() {
        let capture = UUID()
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        _ = buffer.receive("前の字幕", final: true, start: 0, end: 1, speaker: nil, now: 0)
        buffer.clearDisplay()
        XCTAssertTrue(buffer.rows.isEmpty)
        _ = buffer.receive("新しい字幕", final: true, start: 1, end: 2, speaker: nil, now: 1)
        XCTAssertEqual(buffer.rows.count, 1)
        XCTAssertEqual(buffer.rows[0].captureID, capture)
    }

    func testTimelineGapsAndMixedSpeakersRemainUnknown() {
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 1, activeSpeakers: 1, start: 0, end: 0.1, speakerSlot: 0),
            .init(speechProbability: 1, activeSpeakers: 1, start: 0.1, end: 0.2, speakerSlot: 1),
            .init(speechProbability: 1, activeSpeakers: 1, start: 0.3, end: 0.4, speakerSlot: 1)
        ])
        XCTAssertNil(timeline.speaker(start: 0, end: 0.2))
        XCTAssertNil(timeline.decision(start: 0.1, end: 0.4))
        XCTAssertEqual(timeline.speaker(start: 0.3, end: 0.4), 1)
    }
    func testSilenceDurationDoesNotBridgeMissingAudio() {
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0, activeSpeakers: 0, start: 0, end: 1),
            .init(speechProbability: 0, activeSpeakers: 0, start: 2, end: 2.5)
        ])
        XCTAssertEqual(timeline.activity(through: 2.5)?.silence, 0.5)
        XCTAssertNil(timeline.activity(through: 3))
    }
    func testDelayedAnalysisNeverHoldsLivePCMAndPublishesMetadataLater() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.setProviders(analysis: PatternAnalysis(delay: 0.9, voicedUntil: 0.1), enhancement: nil)
        var outputs: [PCMChunk] = []
        for index in 0..<12 {
            let (next, _) = try await pipeline.process(Self.pcm(count: 4800, time: Double(index)/10))
            XCTAssertFalse(next.isEmpty)
            outputs += next
        }
        outputs += try await pipeline.finish()
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertEqual(outputs.reduce(0) { $0+Int($1.buffer.frameLength) }, 57600)
        XCTAssertEqual(outputs.first?.time, 0)
        XCTAssertTrue(outputs.allSatisfy { $0.decision == nil })
        XCTAssertFalse(analysis.isEmpty)
        XCTAssertTrue(analysis.contains { $0.speakerSlot == 0 && $0.speechProbability == 1 })
        XCTAssertTrue(analysis.contains { $0.start >= 0.1-0.00001 && $0.speechProbability == 0 })
    }
    func testEnhancerIsNotCalledWhenAnalysisIsMissing() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.setProviders(analysis: nil, enhancement: enhancer)
        let (outputs, _) = try await pipeline.process(Self.pcm(count: 4800, time: 0))
        let tail = try await pipeline.finish()
        let counts = await enhancer.counts()
        XCTAssertEqual(counts.process, 0); XCTAssertEqual(counts.finish, 0)
        XCTAssertEqual(Self.samples(outputs+tail), [Float](repeating: 0.01, count: 4800))
    }
    func testAnalysisConditionedEnhancerNeverBlocksImmediateLivePCM() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.setProviders(analysis: PatternAnalysis(voicedUntil: 0.1), enhancement: enhancer)
        let (early, _) = try await pipeline.process(Self.pcm(count: 9600, time: 0, amplitude: 0.2))
        let outputs = early + (try await pipeline.finish())
        let counts = await enhancer.counts()
        XCTAssertEqual(counts.process, 0)
        XCTAssertEqual(Self.samples(outputs).count, 9600)
        XCTAssertTrue(Self.samples(outputs).allSatisfy { abs($0-0.2) < 0.0001 })
        for (index, output) in outputs.enumerated() { XCTAssertEqual(output.time, Double(index)/100, accuracy: 0.00001) }
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertFalse(analysis.isEmpty)
    }
    func testAnalysisDelayHasNoTwoSecondGateAndDropsNoAudio() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.setProviders(analysis: PatternAnalysis(delay: 100), enhancement: nil)
        var outputs: [PCMChunk] = []; var sawOldWaitWarning = false
        for index in 0..<30 {
            let (next, state) = try await pipeline.process(Self.pcm(count: 4800, time: Double(index)/10))
            XCTAssertFalse(next.isEmpty)
            outputs += next; sawOldWaitWarning = sawOldWaitWarning || state.warnings.contains(where: { $0.contains("2초") })
        }
        outputs += try await pipeline.finish()
        XCTAssertFalse(sawOldWaitWarning)
        XCTAssertEqual(Self.samples(outputs).count, 144000)
        XCTAssertTrue(outputs.allSatisfy { $0.decision == nil })
    }
    func testShortInputFlushesAnalysisMetadataWithoutHoldingAudio() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.setProviders(analysis: PatternAnalysis(delay: 0.9), enhancement: enhancer)
        let (early, _) = try await pipeline.process(Self.pcm(count: 720, time: 3, amplitude: 0.2))
        XCTAssertFalse(early.isEmpty)
        let outputs = early + (try await pipeline.finish())
        let counts = await enhancer.counts()
        XCTAssertEqual(Self.samples(outputs).count, 720)
        XCTAssertEqual(outputs.first?.time, 3)
        XCTAssertEqual(counts.process, 0)
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertFalse(analysis.isEmpty)
    }
    func testMixedBypassImmediatelyDropsPreviousSpeechGainButKeepsLimiter() {
        var leveler = SpeechLeveler()
        let quiet = [Float](repeating: 0.01, count: 480)
        for _ in 0..<10 { _ = leveler.process(quiet, speechProbability: 1) }
        XCTAssertGreaterThan(leveler.gain, 1)
        XCTAssertEqual(leveler.process(quiet, speechProbability: 1, allowUpwardGain: false), quiet)
        XCTAssertEqual(leveler.gain, 1)
        let loud = leveler.process([Float](repeating: 3, count: 480), speechProbability: 1, allowUpwardGain: false)
        XCTAssertTrue(loud.allSatisfy { abs($0) <= 0.98 })
    }
    func testPipelineOverlapMetadataRunsInParallelWithoutBoostingLivePCM() async throws {
        for active in [2, 3] {
            let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
            await pipeline.setProviders(analysis: PatternAnalysis(voicedUntil: 0.1, laterSpeakers: active), enhancement: enhancer)
            let (early, _) = try await pipeline.process(Self.pcm(count: 9600, time: 0))
            let outputs = early + (try await pipeline.finish())
            let counts = await enhancer.counts()
            let analysis = await pipeline.takeAnalysisUpdates()
            XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.01, count: 9600))
            XCTAssertTrue(outputs.allSatisfy { $0.decision == nil })
            XCTAssertTrue(analysis.contains { $0.activeSpeakers == active })
            XCTAssertEqual(counts.process, 0)
        }
    }
    func testPipelineSilenceMetadataDoesNotDelayOrAlterLivePCM() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.setProviders(analysis: PatternAnalysis(voicedUntil: 0.1), enhancement: nil)
        let (early, _) = try await pipeline.process(Self.pcm(count: 9600, time: 0))
        let outputs = early + (try await pipeline.finish())
        XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.01, count: 9600))
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertTrue(analysis.contains { $0.speechProbability == 0 })
    }
    func testKnownSpeakerChangeMetadataDoesNotGateDifferentVolumePCM() async throws {
        for useEnhancer in [false, true] {
            let pipeline = AudioPreprocessor()
            let enhancer: (any EnhancementProvider)? = useEnhancer ? CountingEnhancer() : nil
            await pipeline.setProviders(analysis: PatternAnalysis(voicedUntil: 0.1, laterSpeakers: 1, laterSlot: 2), enhancement: enhancer)
            let (a, _) = try await pipeline.process(Self.pcm(count: 4800, time: 0, amplitude: 0.01))
            let (b, _) = try await pipeline.process(Self.pcm(count: 4800, time: 0.1, amplitude: 0.2))
            _ = a + b + (try await pipeline.finish())
            XCTAssertEqual(Self.samples(a), [Float](repeating: 0.01, count: 4800))
            XCTAssertEqual(Self.samples(b), [Float](repeating: 0.2, count: 4800))
            let analysis = await pipeline.takeAnalysisUpdates()
            XCTAssertTrue(analysis.contains { $0.speakerSlot == 0 })
            XCTAssertTrue(analysis.contains { $0.speakerSlot == 2 })
        }
    }
    func testUnknownOrLowConfidenceSlotDoesNotResetOrReplaceKnownSpeaker() {
        let ambiguous: [(Float, Int?)] = [(1, nil), (0.5, 2)]
        let quiet = [Float](repeating: 0.01, count: 480)
        for (probability, slot) in ambiguous {
            var leveler = SpeechLeveler()
            for _ in 0..<10 { _ = leveler.process(quiet, speechProbability: 1, speakerSlot: 0) }
            var sameSpeaker = leveler
            XCTAssertEqual(leveler.process(quiet, speechProbability: probability, speakerSlot: slot),
                           sameSpeaker.process(quiet, speechProbability: probability, speakerSlot: 0))
            // Restore a high gain without providing identity, then return to A.
            // An uncertain B must not have replaced A as the last known speaker.
            for _ in 0..<2 {
                _ = leveler.process(quiet, speechProbability: 1)
                _ = sameSpeaker.process(quiet, speechProbability: 1, speakerSlot: 0)
            }
            XCTAssertGreaterThan(leveler.gain, 3)
            XCTAssertEqual(leveler.process(quiet, speechProbability: 1, speakerSlot: 0),
                           sameSpeaker.process(quiet, speechProbability: 1, speakerSlot: 0))
        }
    }
    func testSoftGutterMonologueAndUncertainSpeechStayNeutral() {
        var mapper = SoftSpeakerMapper()
        for time in 0..<8 {
            XCTAssertEqual(mapper.hint(slot: 0, start: Double(time), end: Double(time+1)), .neutral)
        }
        XCTAssertEqual(mapper.hint(slot: nil, start: 8, end: 9), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 9, end: 9.2), .neutral)
        XCTAssertEqual(mapper.hint(slot: 0, start: 9.2, end: 10), .neutral)
    }
    func testSoftGutterSlotsZeroAndTwoGetDistinctLocalHintsAndReturn() {
        var mapper = SoftSpeakerMapper()
        XCTAssertEqual(mapper.hint(slot: 0, start: 0, end: 1), .neutral)
        XCTAssertEqual(mapper.hint(slot: 0, start: 1, end: 2), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 2, end: 3), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 3, end: 4), .second)
        XCTAssertEqual(mapper.hint(slot: 0, start: 4, end: 5), .first)
        XCTAssertEqual(mapper.hint(slot: 2, start: 5, end: 6), .second)
    }
    func testSoftGutterThirdVoiceAndUnknownDoNotDisplaceRecentPair() {
        var mapper = Self.confirmedSpeakerPair()
        XCTAssertEqual(mapper.hint(slot: 8, start: 4, end: 4.5), .neutral)
        XCTAssertEqual(mapper.hint(slot: nil, start: 4.5, end: 5), .neutral)
        XCTAssertEqual(mapper.hint(slot: 0, start: 5, end: 6), .first)
        XCTAssertEqual(mapper.hint(slot: 2, start: 6, end: 7), .second)
    }
    func testSoftGutterAuxiliaryExpiresAndCaptureResetStartsNeutral() {
        var mapper = Self.confirmedSpeakerPair()
        for time in 4..<8 { _ = mapper.hint(slot: 2, start: Double(time), end: Double(time+1)) }
        XCTAssertEqual(mapper.hint(slot: 2, start: 8, end: 9), .neutral)
        XCTAssertEqual(mapper.hint(slot: 0, start: 9, end: 10), .neutral)
        mapper = SoftSpeakerMapper()
        XCTAssertEqual(mapper.hint(slot: 2, start: 0, end: 1), .neutral)
    }
    func testSoftGutterRepeatedAudioRangeDoesNotConfirmCandidate() {
        var mapper = SoftSpeakerMapper()
        _ = mapper.hint(slot: 0, start: 0, end: 1)
        _ = mapper.hint(slot: 0, start: 1, end: 2)
        XCTAssertEqual(mapper.hint(slot: 2, start: 2, end: 4), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 2, end: 4), .neutral)
        XCTAssertEqual(mapper.hint(slot: 0, start: 4, end: 5), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 5, end: 6), .second)
    }
    func testSoftGutterOneOffPrimaryIsNotKeptAsPermanentIdentity() {
        var mapper = SoftSpeakerMapper()
        _ = mapper.hint(slot: 9, start: 0, end: 0.2)
        XCTAssertEqual(mapper.hint(slot: 2, start: 0.2, end: 1.2), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 1.2, end: 2.2), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 2.2, end: 3.2), .neutral)
        XCTAssertEqual(mapper.hint(slot: 9, start: 3.2, end: 3.4), .neutral)
    }
    func testPreparingOptionalModelDoesNotHoldBasicPCMOrCaptureStop() async throws {
        let setup = OptionalProviderPreparation(), gate = SuspendedPreparation()
        await setup.start(analysis: { await gate.suspend(); return PatternAnalysis() }, enhancement: nil)
        await gate.waitUntilStarted()
        let ready = await setup.takeReady()
        XCTAssertNil(ready.analysis)
        XCTAssertTrue(ready.status.contains("준비 중"))
        let pipeline = AudioPreprocessor()
        let (raw, _) = try await pipeline.process(Self.pcm(count: 4800, time: 5))
        XCTAssertEqual(Self.samples(raw), [Float](repeating: 0.01, count: 4800))
        // This must return while the loader is still suspended, before release.
        await setup.cancel()
        await gate.release()
        let closed = await setup.takeReady()
        XCTAssertNil(closed.analysis); XCTAssertNil(closed.enhancement)
        XCTAssertEqual(closed.status, "입력 중지")
        let nextCapture = OptionalProviderPreparation()
        let fresh = await nextCapture.takeReady()
        XCTAssertNil(fresh.analysis); XCTAssertNil(fresh.enhancement)
        _ = try await pipeline.finish()
    }
    func testLateAnalysisStartsAtFollowingPCMWithoutRelabelingEarlierAudio() async throws {
        let pipeline = AudioPreprocessor()
        let (raw, _) = try await pipeline.process(Self.pcm(count: 4800, time: 5, amplitude: 0.2))
        XCTAssertTrue(raw.allSatisfy { $0.decision == nil })
        await pipeline.installPrepared(analysis: PatternAnalysis(delay: 0.1), enhancement: nil)
        let (next, _) = try await pipeline.process(Self.pcm(count: 9600, time: 5.1, amplitude: 0.2))
        let outputs = raw + next + (try await pipeline.finish())
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.2, count: 14400))
        XCTAssertTrue(outputs.allSatisfy { $0.decision == nil })
        XCTAssertTrue(analysis.allSatisfy { $0.start >= 5.1-0.00001 })
        XCTAssertTrue(analysis.contains { $0.speakerSlot == 0 })
    }
    func testLateEnhancerNeverCausesAnalysisBacklogToHoldSTT() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.setProviders(analysis: PatternAnalysis(delay: 100), enhancement: nil)
        let (early, _) = try await pipeline.process(Self.pcm(count: 4800, time: 2, amplitude: 0.2))
        XCTAssertFalse(early.isEmpty)
        await pipeline.installPrepared(analysis: nil, enhancement: enhancer)
        let (next, _) = try await pipeline.process(Self.pcm(count: 4800, time: 2.1, amplitude: 0.2))
        let outputs = early + next + (try await pipeline.finish())
        let counts = await enhancer.counts()
        XCTAssertEqual(counts.process, 0)
        XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.2, count: 9600))
    }
    func testEnhancerReadyBeforeAnalysisStillKeepsLivePathDryAndImmediate() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.installPrepared(analysis: nil, enhancement: enhancer)
        let (raw, _) = try await pipeline.process(Self.pcm(count: 4800, time: 4, amplitude: 0.2))
        let before = await enhancer.counts()
        XCTAssertEqual(before.process, 0)
        await pipeline.installPrepared(analysis: PatternAnalysis(), enhancement: nil)
        let (next, _) = try await pipeline.process(Self.pcm(count: 4800, time: 4.1, amplitude: 0.2))
        let outputs = raw + next + (try await pipeline.finish())
        let after = await enhancer.counts()
        XCTAssertEqual(after.process, 0)
        XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.2, count: 9600))
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertFalse(analysis.isEmpty)
    }
    private static func confirmedSpeakerPair() -> SoftSpeakerMapper {
        var mapper = SoftSpeakerMapper()
        _ = mapper.hint(slot: 0, start: 0, end: 1)
        _ = mapper.hint(slot: 0, start: 1, end: 2)
        _ = mapper.hint(slot: 2, start: 2, end: 3)
        _ = mapper.hint(slot: 2, start: 3, end: 4)
        return mapper
    }
    private static func samples(_ chunks: [PCMChunk]) -> [Float] {
        chunks.flatMap { Array(UnsafeBufferPointer(start: $0.buffer.floatChannelData![0], count: Int($0.buffer.frameLength))) }
    }
    private static func pcm(count: Int, time: Double, amplitude: Float = 0.01) -> PCMChunk {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { buffer.floatChannelData![0][index] = amplitude }
        return PCMChunk(buffer: buffer, time: time)
    }
}

@MainActor
private final class TestQualitySpeechSink: QualitySpeechSink {
    let holdPreparation: Bool
    let holdFinish: Bool
    private var finishReleased = false
    private var finishStarted = false
    private var finishGate: CheckedContinuation<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepared = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var result: ((String, Bool, Double, Double, Double?) -> Void)?
    private(set) var appendCount = 0
    private(set) var abortCount = 0
    init(holdPreparation: Bool, holdFinish: Bool = false) {
        self.holdPreparation = holdPreparation; self.holdFinish = holdFinish
    }
    func prepareForQuality(language: SourceLanguage,
                           result: @escaping (String, Bool, Double, Double, Double?) -> Void,
                           failure: @escaping (String) -> Void) async throws {
        self.result = result; prepared = true
        for waiter in waiters { waiter.resume() }; waiters = []
        if holdPreparation { await withCheckedContinuation { gate = $0 } }
    }
    func waitUntilPreparationStarted() async {
        if prepared { return }
        let deadline = ContinuousClock.now + .seconds(5)
        while !prepared && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(prepared, "Timed out waiting for quality speech preparation")
    }
    func releasePreparation() { gate?.resume(); gate = nil }
    func emitResult() { result?("遅れて届いた結果。", true, 0, 1, 1) }
    func append(_ chunk: PCMChunk) { appendCount += 1 }
    func finish(aborting: Bool) async {
        if aborting { abortCount += 1 }
        finishStarted = true
        for waiter in finishWaiters { waiter.resume() }; finishWaiters = []
        if holdFinish && !finishReleased { await withCheckedContinuation { finishGate = $0 } }
    }
    func waitUntilFinishStarted() async {
        if finishStarted { return }
        let deadline = ContinuousClock.now + .seconds(5)
        while !finishStarted && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(finishStarted, "Timed out waiting for quality speech finish")
    }
    func releaseFinish() { finishReleased = true; finishGate?.resume(); finishGate = nil }
}

private actor SuspendedPreparation {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; started = true
            for waiter in startedWaiters { waiter.resume() }; startedWaiters = []
        }
    }
    func waitUntilStarted() async {
        if started { return }
        let deadline = ContinuousClock.now + .seconds(5)
        while !started && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(started, "Timed out waiting for synthetic provider preparation")
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor FailingEnhancer: EnhancementProvider {
    private var dry: [Float] = []
    func process(_ mono: [Float], sampleRate: Double, wetMix: Float) throws -> [Float] {
        dry += mono
        if dry.count > 480 { throw AppFailure.message("intentional test failure") }
        return []
    }
    func finish() -> [Float] { [] }
    func recoverUnprocessed() -> [Float] { let value = dry; dry = []; return value }
}

// Synthetic delayed analysis: frame times stay tied to input, regardless of arrival.
private actor PatternAnalysis: SpeechAnalysisProvider {
    let delay: Double
    let voicedUntil: Double
    let laterSpeakers: Int
    let laterSlot: Int?
    private var elapsed: Double = 0
    private var emitted: Double = 0
    init(delay: Double = 0, voicedUntil: Double = 1000, laterSpeakers: Int = 0, laterSlot: Int? = nil) {
        self.delay = delay; self.voicedUntil = voicedUntil; self.laterSpeakers = laterSpeakers; self.laterSlot = laterSlot
    }
    func process(_ mono: [Float], sampleRate: Double) -> [SpeechDecision] {
        elapsed += Double(mono.count)/sampleRate
        return frames(through: max(0, elapsed-delay))
    }
    func finish() -> [SpeechDecision] { frames(through: elapsed) }
    func reset() { elapsed = 0; emitted = 0 }
    private func frames(through end: Double) -> [SpeechDecision] {
        var output: [SpeechDecision] = []
        while emitted < end-0.000001 {
            let next = min(end, emitted+0.01)
            let voiced = emitted < voicedUntil-0.000001
            output.append(.init(speechProbability: voiced || laterSpeakers > 0 ? 1 : 0, activeSpeakers: voiced ? 1 : laterSpeakers,
                start: emitted, end: next, speakerSlot: voiced ? 0 : (laterSpeakers == 1 ? laterSlot : nil)))
            emitted = next
        }
        return output
    }
}

private actor CountingEnhancer: EnhancementProvider {
    private var processCalls = 0, finishCalls = 0, resetCalls = 0
    private var dry: [Float] = []
    func process(_ mono: [Float], sampleRate: Double, wetMix: Float) -> [Float] {
        processCalls += 1; dry += mono
        let count = max(0, dry.count-480)
        let output = Array(dry.prefix(count)); dry.removeFirst(count); return output
    }
    func finish() -> [Float] { finishCalls += 1; let output = dry; dry = []; return output }
    func recoverUnprocessed() -> [Float] { resetCalls += 1; let output = dry; dry = []; return output }
    func counts() -> (process: Int, finish: Int, reset: Int) { (processCalls, finishCalls, resetCalls) }
}
