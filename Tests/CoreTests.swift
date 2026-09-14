import XCTest
import AVFoundation
@testable import JPLive

final class CoreTests: XCTestCase {
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
    #if targetEnvironment(simulator)
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
    func testContinuationBoundaryAndLosslessSplit() {
        XCTAssertFalse(ChunkBoundary.shouldCommit("そうだけど", pause: 0.7, duration: 3, language: .japanese))
        XCTAssertTrue(ChunkBoundary.shouldCommit("そうです。", pause: 0, duration: 1, language: .japanese))
        let long = String(repeating: "これはテストです。", count: 30)
        XCTAssertEqual(ChunkBoundary.split(long, limit: 110).joined(), long)
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
        XCTAssertEqual(buffer.tick(now: 2, activity: AudioActivity(through: 3.3, speaking: false, silence: 1.3)), [firstID])
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
        _ = buffer.finish()
        let group = buffer.rows[0].contextGroup
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("はい。", final: true, start: 0, end: 1, speaker: nil, now: 0)
        XCTAssertEqual(buffer.rows.count, 2)
        XCTAssertNotEqual(buffer.rows[1].contextGroup, group)
    }
    func testUnfinalizedAndEnglishCaptionsCannotBeSaved() {
        let session = LearningSession(id: "s", title: nil, raw_url: nil, session_key: nil)
        for (language, final) in [(SourceLanguage.japanese, false), (.english, true)] {
            let row = Caption(captureID: UUID(), language: language, source: "test", start: 0, end: 1, isFinal: final)
            XCTAssertThrowsError(try SavePayload.make(caption: row, session: session, token: nil, tokens: [], translation: ""))
        }
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
        XCTAssertEqual(buffer.tick(now: 2.3), [id])
        XCTAssertTrue(buffer.rows[0].isFinal)
    }
    func testRevocationDoesNotRemoveCommittedHistory() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("はい。", final: true, start: 0, end: 1, speaker: nil, now: 0)
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
    func testDetectedSilenceRespectsJapaneseContinuationEnding() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("そうだけど", final: true, start: 0, end: 1, speaker: nil, now: 0)
        XCTAssertTrue(buffer.tick(now: 2, activity: AudioActivity(through: 1.7, speaking: false, silence: 0.7)).isEmpty)
        XCTAssertEqual(buffer.tick(now: 2.5, activity: AudioActivity(through: 2.3, speaking: false, silence: 1.3)).count, 1)
    }
    func testMaxDurationCommitsOnlyFinalPrefixAndKeepsVolatileTail() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("前半", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.receive("続く話", final: false, start: 1, end: 10, speaker: nil, now: 10)
        XCTAssertEqual(buffer.tick(now: 10, activity: AudioActivity(through: 10, speaking: true, silence: 0)).count, 1)
        XCTAssertEqual(buffer.rows.map(\.source), ["前半", "続く話"])
        XCTAssertTrue(buffer.rows[0].isFinal)
        XCTAssertFalse(buffer.rows[1].isFinal)
    }
    func testKnownSpeakerChangeSeparatesFinalPhrasesButUnknownDoesNot() {
        let speakers: [Int?] = [0, nil]
        for first in speakers {
            var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
            _ = buffer.receive("昨日", final: true, start: 0, end: 1, speaker: first, now: 0)
            let ready = buffer.receive("ゲーム", final: true, start: 1, end: 2, speaker: 1, now: 0.1)
            XCTAssertEqual(ready.count, first == nil ? 0 : 1)
            XCTAssertEqual(buffer.rows.count, first == nil ? 1 : 2)
        }
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
    func testDelayedAnalysisAppliesToBufferedOriginalAudio() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.setProviders(analysis: PatternAnalysis(delay: 0.9, voicedUntil: 0.1), enhancement: nil)
        var outputs: [PCMChunk] = []
        for index in 0..<12 {
            let (next, _) = try await pipeline.process(Self.pcm(count: 4800, time: Double(index)/10))
            outputs += next
        }
        outputs += try await pipeline.finish()
        XCTAssertEqual(outputs.reduce(0) { $0+Int($1.buffer.frameLength) }, 57600)
        XCTAssertEqual(outputs.first?.time, 0)
        XCTAssertEqual(outputs.first?.decision?.speakerSlot, 0)
        XCTAssertEqual(outputs.first?.decision?.speechProbability, 1)
        for output in outputs where output.time >= 0.1-0.00001 {
            XCTAssertEqual(output.decision?.speechProbability, 0)
            XCTAssertNil(output.decision?.speakerSlot)
        }
        XCTAssertGreaterThan(Self.samples(Array(outputs.prefix(10))).max() ?? 0, 0.01)
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
    func testEnhancerBypassRestoresTailAndNeverProcessesSilentInterval() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.setProviders(analysis: PatternAnalysis(voicedUntil: 0.1), enhancement: enhancer)
        let (early, _) = try await pipeline.process(Self.pcm(count: 9600, time: 0, amplitude: 0.2))
        let outputs = early + (try await pipeline.finish())
        let counts = await enhancer.counts()
        XCTAssertEqual(counts.process, 10)
        XCTAssertEqual(counts.finish, 0)
        XCTAssertEqual(counts.reset, 1)
        XCTAssertEqual(Self.samples(outputs).count, 9600)
        XCTAssertTrue(Self.samples(outputs).allSatisfy { abs($0-0.2) < 0.0001 })
        for (index, output) in outputs.enumerated() { XCTAssertEqual(output.time, Double(index)/100, accuracy: 0.00001) }
    }
    func testAnalysisBudgetFallsBackWithoutDroppingAudio() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.setProviders(analysis: PatternAnalysis(delay: 100), enhancement: nil)
        var outputs: [PCMChunk] = []; var sawWarning = false
        for index in 0..<30 {
            let (next, state) = try await pipeline.process(Self.pcm(count: 4800, time: Double(index)/10))
            outputs += next; sawWarning = sawWarning || state.warnings.contains(where: { $0.contains("2초") })
        }
        outputs += try await pipeline.finish()
        XCTAssertTrue(sawWarning)
        XCTAssertEqual(Self.samples(outputs).count, 144000)
        XCTAssertTrue(outputs.allSatisfy { $0.decision == nil })
    }
    func testShortInputFlushesAnalysisAndEnhancementTail() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.setProviders(analysis: PatternAnalysis(delay: 0.9), enhancement: enhancer)
        let (early, _) = try await pipeline.process(Self.pcm(count: 720, time: 3, amplitude: 0.2))
        let outputs = early + (try await pipeline.finish())
        let counts = await enhancer.counts()
        XCTAssertEqual(Self.samples(outputs).count, 720)
        XCTAssertEqual(outputs.first?.time, 3)
        XCTAssertEqual(counts.finish, 1)
        XCTAssertTrue(outputs.allSatisfy { $0.decision?.speakerSlot == 0 })
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
    func testPipelineOverlapDoesNotBoostMixedAudioOrRunEnhancer() async throws {
        for active in [2, 3] {
            let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
            await pipeline.setProviders(analysis: PatternAnalysis(voicedUntil: 0.1, laterSpeakers: active), enhancement: enhancer)
            let (early, _) = try await pipeline.process(Self.pcm(count: 9600, time: 0))
            let outputs = early + (try await pipeline.finish())
            let counts = await enhancer.counts()
            XCTAssertEqual(Self.samples(outputs).count, 9600)
            XCTAssertGreaterThan(Self.samples(outputs.filter { $0.time < 0.1-0.00001 }).max() ?? 0, 0.01)
            let overlap = outputs.filter { $0.time >= 0.1-0.00001 }
            XCTAssertEqual(Self.samples(overlap), [Float](repeating: 0.01, count: 4800))
            XCTAssertTrue(overlap.allSatisfy { $0.decision?.activeSpeakers == active && $0.decision?.speechProbability == 1 })
            XCTAssertEqual(counts.process, 10)
            XCTAssertEqual(counts.finish, 0)
        }
    }
    func testPipelineSilenceDoesNotInheritSingleSpeakerGain() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.setProviders(analysis: PatternAnalysis(voicedUntil: 0.1), enhancement: nil)
        let (early, _) = try await pipeline.process(Self.pcm(count: 9600, time: 0))
        let outputs = early + (try await pipeline.finish())
        XCTAssertGreaterThan(Self.samples(outputs.filter { $0.time < 0.1-0.00001 }).max() ?? 0, 0.01)
        XCTAssertEqual(Self.samples(outputs.filter { $0.time >= 0.1-0.00001 }), [Float](repeating: 0.01, count: 4800))
    }
    func testKnownSpeakerChangeDoesNotPassQuietSpeakerGainToLoudSpeaker() async throws {
        // Also exercise a delayed enhancer output: reset must follow original
        // audio order, including the first B frame emitted from its output ledger.
        for useEnhancer in [false, true] {
            let pipeline = AudioPreprocessor()
            let enhancer: (any EnhancementProvider)? = useEnhancer ? CountingEnhancer() : nil
            await pipeline.setProviders(analysis: PatternAnalysis(voicedUntil: 0.1, laterSpeakers: 1, laterSlot: 2), enhancement: enhancer)
            let (a, _) = try await pipeline.process(Self.pcm(count: 4800, time: 0, amplitude: 0.01))
            let (b, _) = try await pipeline.process(Self.pcm(count: 4800, time: 0.1, amplitude: 0.2))
            let outputs = a + b + (try await pipeline.finish())
            let quiet = outputs.filter { $0.time < 0.1-0.00001 }
            let loud = outputs.filter { $0.time >= 0.1-0.00001 }
            XCTAssertEqual(Self.samples(outputs).count, 9600)
            XCTAssertGreaterThan(Self.samples(quiet).max() ?? 0, 0.03)
            XCTAssertEqual(loud.first?.time ?? -1, 0.1, accuracy: 0.00001)
            XCTAssertTrue(quiet.allSatisfy { $0.decision?.speakerSlot == 0 })
            XCTAssertTrue(loud.allSatisfy { $0.decision?.speakerSlot == 2 && $0.decision?.activeSpeakers == 1 })
            // Exact equality includes B's first sample, not merely its steady state.
            XCTAssertEqual(Self.samples(loud), [Float](repeating: 0.2, count: 4800))
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
        let analyzed = next + (try await pipeline.finish())
        XCTAssertEqual(Self.samples(raw + analyzed), [Float](repeating: 0.2, count: 14400))
        XCTAssertEqual(analyzed.first?.time ?? -1, 5.1, accuracy: 0.00001)
        XCTAssertTrue(analyzed.allSatisfy { $0.decision?.speakerSlot == 0 })
        for (index, frame) in (raw + analyzed).enumerated() {
            XCTAssertEqual(frame.time, 5 + Double(index)/100, accuracy: 0.00001)
        }
        for frame in analyzed {
            XCTAssertEqual(frame.decision?.start ?? -1, frame.time, accuracy: 0.00001)
        }
    }
    func testLateEnhancerDoesNotReprocessAnalysisBacklogBeforeActivation() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.setProviders(analysis: PatternAnalysis(delay: 100), enhancement: nil)
        let (early, _) = try await pipeline.process(Self.pcm(count: 4800, time: 2, amplitude: 0.2))
        XCTAssertTrue(early.isEmpty)
        await pipeline.installPrepared(analysis: nil, enhancement: enhancer)
        let (next, _) = try await pipeline.process(Self.pcm(count: 4800, time: 2.1, amplitude: 0.2))
        let outputs = early + next + (try await pipeline.finish())
        let counts = await enhancer.counts()
        XCTAssertEqual(counts.process, 10) // Only the ten frames at/after 2.1.
        XCTAssertEqual(counts.finish, 1)
        XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.2, count: 9600))
        for (index, frame) in outputs.enumerated() {
            XCTAssertEqual(frame.time, 2 + Double(index)/100, accuracy: 0.00001)
        }
    }
    func testEnhancerReadyBeforeAnalysisStillUsesRawPathUntilAnalysisArrives() async throws {
        let pipeline = AudioPreprocessor(), enhancer = CountingEnhancer()
        await pipeline.installPrepared(analysis: nil, enhancement: enhancer)
        let (raw, _) = try await pipeline.process(Self.pcm(count: 4800, time: 4, amplitude: 0.2))
        let before = await enhancer.counts()
        XCTAssertEqual(before.process, 0)
        await pipeline.installPrepared(analysis: PatternAnalysis(), enhancement: nil)
        let (next, _) = try await pipeline.process(Self.pcm(count: 4800, time: 4.1, amplitude: 0.2))
        let outputs = raw + next + (try await pipeline.finish())
        let after = await enhancer.counts()
        XCTAssertEqual(after.process, 10)
        XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.2, count: 9600))
        XCTAssertTrue(raw.allSatisfy { $0.decision == nil })
        XCTAssertEqual(outputs.last?.decision?.end ?? -1, 4.2, accuracy: 0.00001)
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
        await withCheckedContinuation { startedWaiters.append($0) }
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
