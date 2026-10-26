import XCTest
import AVFoundation
@testable import JPLive

final class CoreTests: XCTestCase {
    func testR5HRecentSpeakerRowIndicesRetainLegacyOrderAndSelection() {
        let previousCapture = UUID(), activeCapture = UUID()
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: activeCapture, language: .japanese)
        for number in 0..<2_000 {
            let capture = number < 150 ? previousCapture : activeCapture
            // Include drafts, already-ended epochs, and interleaved nonfinal rows.
            buffer.rows.append(Caption(captureID: capture, language: .japanese,
                source: "行\(number)", start: Double(number), end: Double(number + 1),
                isFinal: number % 7 != 0))
        }
        for minEnd: Double? in [nil, 140.0, 1_850.0, 2_500.0] {
            for limit in [0, 1, 2, 32, 100, 3_000] {
                let legacy = Array(buffer.rows.indices.filter { index in
                    let row = buffer.rows[index]
                    return row.captureID == activeCapture && row.isFinal &&
                        (minEnd.map { row.end > $0 } ?? true)
                }.suffix(limit))
                XCTAssertEqual(buffer.recentFinalSpeakerRowIndices(
                    captureID: activeCapture, minimumEnd: minEnd, limit: limit), legacy)
            }
        }
        XCTAssertTrue(buffer.recentFinalSpeakerRowIndices(captureID: UUID()).isEmpty)
    }

    func testR5JNewCaptureBoundaryPreservesRecentSpeakerSelection() {
        let older = UUID(), active = UUID()
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: older, language: .japanese)
        for n in 0..<2_000 {
            buffer.rows.append(Caption(captureID: older, language: .japanese,
                source: "前\(n)", start: Double(n), end: Double(n + 1), isFinal: true))
        }
        buffer.begin(captureID: active, language: .japanese)
        XCTAssertEqual(buffer.rows.count, 2_000) // Stop/Start retains prior captions.
        // This is the expensive R5I case: no current final text yet.
        XCTAssertTrue(buffer.recentFinalSpeakerRowIndices(captureID: active).isEmpty)
        for count in [0, 1, 10, 31, 32, 40] {
            let start = buffer.rows.count
            for n in 0..<count {
                buffer.rows.append(Caption(captureID: active, language: .japanese,
                    source: "現\(n)", start: Double(n), end: Double(n + 1),
                    isFinal: n % 5 != 0))
            }
            buffer.rows.append(Caption(captureID: active, language: .japanese,
                source: "未確定", start: 100, end: 101, isFinal: false))
            for minimumEnd: Double? in [nil, 0, 5, 30, 1_000] {
                for limit in [0, 1, 2, 32, 120] {
                    let legacy = Array(buffer.rows.indices.filter { index in
                        let row = buffer.rows[index]
                        return row.captureID == active && row.isFinal &&
                            (minimumEnd.map { row.end > $0 } ?? true)
                    }.suffix(limit))
                    XCTAssertEqual(buffer.recentFinalSpeakerRowIndices(
                        captureID: active, minimumEnd: minimumEnd, limit: limit), legacy)
                }
            }
            buffer.rows.removeSubrange(start..<buffer.rows.count)
        }
    }

    #if PHASE2
    @MainActor
    func testCaptureSelectionQueueSerializesPickerTransitions() async {
        let queue = CaptureSelectionQueue()
        var order: [String] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        queue.enqueue {
            order.append("first begin")
            await withCheckedContinuation { releaseFirst = $0 }
            order.append("first end")
        }
        queue.enqueue { order.append("second begin") }
        for _ in 0..<100 where releaseFirst == nil { await Task.yield() }
        XCTAssertEqual(order, ["first begin"])
        releaseFirst?.resume()
        await queue.drain()
        XCTAssertEqual(order, ["first begin", "first end", "second begin"])
    }

    @MainActor
    func testUnconfirmedNativeStopBlocksNewCaptureUntilConfirmed() {
        let ledger = CaptureNativeStopLedger()
        let first = NSObject()
        let second = NSObject()
        XCTAssertTrue(ledger.canStart)
        ledger.beganStopping(first)
        ledger.beganStopping(second)
        XCTAssertFalse(ledger.canStart)
        ledger.confirmedStopped(first)
        XCTAssertFalse(ledger.canStart)
        ledger.confirmedStopped(second)
        XCTAssertTrue(ledger.canStart)
    }
    @MainActor
    func testR5GNativeStopCallsAreCoalescedAndConfirmed() async throws {
        let stops = CaptureNativeStopFlights()
        let source = NSObject()
        var count = 0
        var release: CheckedContinuation<Void, Never>?
        let one = Task { @MainActor in
            try await stops.stop(source) {
                count += 1
                await withCheckedContinuation { release = $0 }
            }
        }
        for _ in 0..<100 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)
        let two = Task { @MainActor in
            try await stops.stop(source) { count += 100 }
        }
        for _ in 0..<10 { await Task.yield() }
        release?.resume()
        try await one.value
        try await two.value
        try await stops.stop(source) { count += 1000 }
        XCTAssertEqual(count, 1, "Repeated stop must not restart an already-successful native stop")
    }

    @MainActor
    func testR5GFailedNativeStopRetainsLedgerUntilRetry() async throws {
        let stops = CaptureNativeStopFlights()
        let source = NSObject()
        do {
            try await stops.stop(source) { throw NSError(domain: "fake.native", code: 1) }
            XCTFail("Expected simulated native stop failure")
        } catch { /* fail-closed */ }
        XCTAssertFalse(CaptureNativeStopLedger.shared.canStart)
        try await stops.stop(source) {}
        XCTAssertTrue(CaptureNativeStopLedger.shared.canStart)
    }

    #endif

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

    @MainActor
    func testDebouncePreservesMultipleDisjointVolatileRangesAtEOF() {
        let model = AppModel()
        defer { model.clearTranscript() }
        model.receivePrimarySpeech(.init(text: "今日は", final: false, start: 0, end: 1, finalizedThrough: 0),
                                   language: .japanese)
        model.receivePrimarySpeech(.init(text: "晴れ。", final: false, start: 1, end: 2, finalizedThrough: 0),
                                   language: .japanese)
        _ = model.finishPrimaryTranscript(language: .japanese)
        XCTAssertEqual(model.captions.map(\.source), ["今日は晴れ。"])
        XCTAssertEqual(model.captions.first?.isFinal, false)
        XCTAssertEqual(model.captions.first?.translationError, "인식 종료 · 미확정 원문")
    }

    func testSpeechTimelineKeepsSuffixOfPartiallyOverlappingRecoveryFrame() {
        var timeline = SpeechTimeline()
        timeline.append([SpeechDecision(speechProbability: 0.9, activeSpeakers: 1,
            start: 100.0, end: 100.1, speakerSlot: 1, identityEpoch: 0)])
        timeline.append([SpeechDecision(speechProbability: 0.9, activeSpeakers: 1,
            start: 100.023, end: 100.123, speakerSlot: 11, identityEpoch: 1)])
        XCTAssertEqual(timeline.frames.count, 2)
        XCTAssertEqual(timeline.frames[1].start, 100.1, accuracy: 0.000001)
        XCTAssertEqual(timeline.frames[1].end, 100.123, accuracy: 0.000001)
        XCTAssertNotNil(timeline.decision(start: 100.1, end: 100.12))
    }

    func testR5GScreenshotCaptureIdentityRejectsHistoricalCaptions() {
        let previous = UUID(), current = UUID()
        XCTAssertFalse(ScreenshotCapturePolicy.matches(caption: previous, current: current, running: true))
        XCTAssertFalse(ScreenshotCapturePolicy.matches(caption: current, current: current, running: false))
        XCTAssertTrue(ScreenshotCapturePolicy.matches(caption: current, current: current, running: true))
    }

    func testR5MScreenshotPolicyRequiresCurrentPickerAudioSource() {
        let capture = UUID()
        // Both captions belong to the SAME capture UUID. Picker B starts at 10 s.
        XCTAssertTrue(ScreenshotCapturePolicy.matches(caption: capture, current: capture, running: true))
        XCTAssertFalse(ScreenshotSourcePolicy.matches(sentenceStart: 2, sentenceEnd: 3,
            currentSourceFirstAudioTime: 10))
        XCTAssertTrue(ScreenshotSourcePolicy.matches(sentenceStart: 10, sentenceEnd: 11,
            currentSourceFirstAudioTime: 10))
        XCTAssertTrue(ScreenshotSourcePolicy.matches(sentenceStart: 12, sentenceEnd: 13,
            currentSourceFirstAudioTime: 10))
        // The picker has switched, but stream B has not delivered PCM yet.
        XCTAssertFalse(ScreenshotSourcePolicy.matches(sentenceStart: 12, sentenceEnd: 13,
            currentSourceFirstAudioTime: nil))
        // Straddling the audio source boundary must not produce a mismatched photo.
        XCTAssertFalse(ScreenshotSourcePolicy.matches(sentenceStart: 9, sentenceEnd: 11,
            currentSourceFirstAudioTime: 10))
        // An invalid or missing timestamp must also suppress only the screenshot.
        XCTAssertFalse(ScreenshotSourcePolicy.matches(sentenceStart: .nan, sentenceEnd: 13,
            currentSourceFirstAudioTime: 10))
        XCTAssertFalse(ScreenshotSourcePolicy.matches(sentenceStart: 12, sentenceEnd: 12,
            currentSourceFirstAudioTime: 10))
    }

    func testR5BEpochDistinctIdentitiesNeverMergeByNumericSlot() {
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0, end: 1,
                  speakerSlot: 0, identityEpoch: 10),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 1, end: 2,
                  speakerSlot: 0, identityEpoch: 11)
        ])
        XCTAssertNil(timeline.speaker(start: 0, end: 2))
        XCTAssertNil(timeline.decision(start: 0, end: 2)?.speakerSlot)
        XCTAssertNil(timeline.confidentSingleSpeaker(start: 0, end: 2))
        XCTAssertTrue(timeline.hasMultipleSpeakersOrOverlap(start: 0, end: 2))
        let timed = [TimedTextSpan(utf16Start: 0, utf16End: 1, start: 0, end: 1),
                     TimedTextSpan(utf16Start: 1, utf16End: 2, start: 1, end: 2)]
        let spans = timeline.speakerSpans(for: timed)
        XCTAssertEqual(spans.map(\.identityEpoch), [10, 11])
        XCTAssertNil(timeline.summarySpeaker(for: spans))

        let capture = UUID()
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [Caption(captureID: capture, language: .japanese,
            source: "甲乙", start: 0, end: 2, isFinal: true, timedTextSpans: timed)]
        _ = buffer.applySpeakerTimeline(timeline)
        XCTAssertNil(buffer.rows[0].speaker)
        var mapper = SoftSpeakerMapper()
        XCTAssertEqual(mapper.hint(for: buffer.rows[0]), .mixed)

        var control = SpeechTimeline()
        control.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0, end: 1,
                  speakerSlot: 0, identityEpoch: 10),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 1, end: 2,
                  speakerSlot: 0, identityEpoch: 10)
        ])
        XCTAssertEqual(control.speaker(start: 0, end: 2), 0)
        XCTAssertFalse(control.hasMultipleSpeakersOrOverlap(start: 0, end: 2))
        XCTAssertEqual(control.summarySpeaker(for: control.speakerSpans(for: timed)), 0)
    }

    func testR5BPopupAnalysisKeyIgnoresMetadataRevisionButNotSource() {
        let generation = UUID()
        var row = Caption(captureID: UUID(), language: .japanese,
                          source: "乙", start: 1, end: 2, isFinal: true)
        row.semanticSentenceID = UUID()
        row.semanticSentenceSource = "前甲乙後"
        let key = PopupAnalysisIdentity.morphologyKey(mode: "C", row: row)
        let meaning = PopupAnalysisIdentity.meaningKey(
            mode: "C", row: row, tokenID: "0:1", useAI: false, generation: generation)
        row.revision += 1
        row.speaker = 1
        row.translation = "한국어"
        XCTAssertEqual(PopupAnalysisIdentity.morphologyKey(mode: "C", row: row), key)
        XCTAssertEqual(PopupAnalysisIdentity.meaningKey(
            mode: "C", row: row, tokenID: "0:1", useAI: false, generation: generation), meaning)
        row.semanticSentenceSource = "前甲乙後。"
        XCTAssertEqual(PopupAnalysisIdentity.morphologyKey(mode: "C", row: row), key)
        XCTAssertNotEqual(PopupAnalysisIdentity.meaningKey(
            mode: "C", row: row, tokenID: "0:1", useAI: false, generation: generation), meaning)
        row.source = "甲乙"
        XCTAssertNotEqual(PopupAnalysisIdentity.morphologyKey(mode: "C", row: row), key)
    }

    func testSpeechDecisionShiftPreservesIdentityEpoch() {
        let value = SpeechDecision(speechProbability: 1, activeSpeakers: 1, start: 0, end: 0.1,
                                   speakerSlot: 12, identityEpoch: 3).shifted(by: 10)
        XCTAssertEqual(value.identityEpoch, 3)
        XCTAssertEqual(value.start, 10, accuracy: 0.000001)
    }

    func testSeparatedLocalLaneDoesNotMutateOrPretendToBeDiarizerIdentity() {
        var mapper = SoftSpeakerMapper()
        _ = mapper.hint(slot: 7, start: 0, end: 1)
        var control = mapper
        var row = Caption(captureID: UUID(), language: .japanese, source: "分離。", start: 100, end: 101,
                          isFinal: true, gutterHint: .mixed, separationLane: 0, separationGroup: UUID())
        XCTAssertEqual(mapper.hint(for: row), .mixed)
        row.separationLane = 1
        XCTAssertEqual(mapper.hint(for: row), .mixed)
        XCTAssertNil(row.speaker, "separator lane 0/1 is not a global diarizer slot")
        for index in 1...8 {
            let start = Double(index)
            XCTAssertEqual(mapper.hint(slot: index % 2, start: start, end: start+1),
                           control.hint(slot: index % 2, start: start, end: start+1))
        }
    }

    @MainActor


    @MainActor


    @MainActor


    @MainActor
    func testSeparationEOFConsidersFinalRowsWithoutLoadingMissingPCM() async {
        var timeline = SpeechTimeline()
        timeline.append((0..<3).map { .init(speechProbability: 0.9, activeSpeakers: 2,
            start: Double($0)*0.1, end: Double($0+1)*0.1) })
        let row = Caption(captureID: UUID(), language: .japanese, source: "最後の会話。", start: 0, end: 0.3, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: "最後の会話。".utf16.count, start: 0, end: 0.3)])
        let pass = LiveSeparationPass(modelURL: URL(fileURLWithPath: "/unavailable/Separator.mlmodelc"),
            currentRows: { [row] }, currentTimeline: { timeline }, deliver: { _, _, _ in
                XCTFail("No PCM must not produce separated rows"); return []
            }, remap: { _, _ in XCTFail("No separation means no remap") })
        await pass.finish()
        XCTAssertEqual(pass.diagnostics.skipped, 1)
        XCTAssertEqual(pass.diagnostics.attempted, 0)
        XCTAssertFalse(pass.diagnostics.busy)
        XCTAssertEqual(pass.diagnostics.status, "입력 종료 · 분리 처리 종료")
        pass.consider(fastBacklog: 0)
        XCTAssertEqual(pass.diagnostics.skipped, 1, "EOF must close the pass")
    }

    @MainActor
    func testExplicitStopPreventsEOFSeparationScheduling() async {
        var timeline = SpeechTimeline()
        timeline.append((0..<3).map { .init(speechProbability: 0.9, activeSpeakers: 2,
            start: Double($0)*0.1, end: Double($0+1)*0.1) })
        let row = Caption(captureID: UUID(), language: .japanese, source: "最後の会話。", start: 0, end: 0.3, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: "最後の会話。".utf16.count, start: 0, end: 0.3)])
        let pass = LiveSeparationPass(modelURL: URL(fileURLWithPath: "/unavailable/Separator.mlmodelc"),
            currentRows: { [row] }, currentTimeline: { timeline }, deliver: { _, _, _ in
                XCTFail("Stopped pass must not deliver rows"); return []
            }, remap: { _, _ in XCTFail("Stopped pass must not remap") })
        pass.stop()
        await pass.finish()
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

    func testSeparationReplacesOnlyOverlapTextAndPreservesPrimaryOutsideIt() {
        let capture = UUID()
        let spans = [
            TimedTextSpan(utf16Start: 0, utf16End: 1, start: 0, end: 4.9),
            TimedTextSpan(utf16Start: 1, utf16End: 2, start: 4.9, end: 5.1),
            TimedTextSpan(utf16Start: 2, utf16End: 3, start: 5.1, end: 10)
        ]
        let original = Caption(captureID: capture, language: .japanese, source: "前重後",
            translation: "기존 번역", start: 0, end: 10, isFinal: true, timedTextSpans: spans)
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [original]
        let target = OverlapEpisode(start: 4.9, end: 5.1)
        let a = Caption(captureID: UUID(), language: .japanese, source: "甲", start: 4.9, end: 5.1,
            isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 4.9, end: 5.1)],
            separationLane: 0)
        let b = Caption(captureID: UUID(), language: .japanese, source: "乙", start: 4.9, end: 5.1,
            isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 4.9, end: 5.1)],
            separationLane: 1)
        XCTAssertTrue(buffer.applySeparation(original: original, target: target, separated: [a]).isEmpty)
        XCTAssertEqual(buffer.rows[0].translation, "기존 번역")
        let ids = buffer.applySeparation(original: original, target: target, separated: [a,b])
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(ids[0], original.id)
        XCTAssertEqual(buffer.rows.map(\.source), ["前", "甲", "乙", "後"])
        XCTAssertNil(buffer.rows[0].separationGroup)
        XCTAssertEqual(buffer.rows[1].separationGroup, buffer.rows[2].separationGroup)
        XCTAssertNotNil(buffer.rows[1].separationGroup)
        XCTAssertNil(buffer.rows[3].separationGroup)
        XCTAssertEqual(buffer.rows[1].separationLane, 0)
        XCTAssertEqual(buffer.rows[2].separationLane, 1)
        XCTAssertNil(buffer.rows[1].speaker, "local separator lane must not masquerade as a global speaker")
        XCTAssertEqual(buffer.rows[1].gutterHint, .mixed)
        XCTAssertTrue(buffer.rows.allSatisfy { $0.captureID == capture && $0.translation.isEmpty })
        XCTAssertTrue(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty)
    }

    func testPopupSemanticSentenceLookupUsesOwningVisualIndexAndKeepsHistoricalCaptions() {
        let oldCapture = UUID(), activeCapture = UUID()
        var rows: [Caption] = []
        for i in 0..<1200 {
            rows.append(Caption(captureID: oldCapture, language: .japanese,
                                source: "履歴\(i)", start: Double(i), end: Double(i + 1), isFinal: true))
        }
        let original = Caption(captureID: activeCapture, language: .japanese,
                               source: "前重後", start: 0, end: 10, isFinal: true,
                               timedTextSpans: [
                                .init(utf16Start: 0, utf16End: 1, start: 0, end: 4.9),
                                .init(utf16Start: 1, utf16End: 2, start: 4.9, end: 5.1),
                                .init(utf16Start: 2, utf16End: 3, start: 5.1, end: 10)
                               ])
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: activeCapture, language: .japanese)
        buffer.rows = rows + [original]
        let a = Caption(captureID: activeCapture, language: .japanese, source: "甲", start: 4.9, end: 5.1,
                        isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 4.9, end: 5.1)], separationLane: 0)
        var b = a; b.source = "乙"; b.separationLane = 1
        XCTAssertEqual(buffer.applySeparation(original: original, target: .init(start: 4.9, end: 5.1), separated: [a, b]).count, 4)
        let fragmentIndex = rows.count + 2
        let fragment = buffer.rows[fragmentIndex]
        let restored = PopupSemanticSentence.resolve(current: fragment, rows: buffer.rows, currentIndex: fragmentIndex)
        XCTAssertEqual(restored?.source, "前甲乙後")
        XCTAssertEqual(restored?.id, original.id)
        XCTAssertEqual(restored?.contextGroup, fragment.contextGroup)
        XCTAssertNil(PopupSemanticSentence.resolve(current: fragment, rows: buffer.rows, currentIndex: 0),
                     "Wrong/stale index must not silently return an unrelated semantic sentence")
        let earlier = PopupSemanticSentence.resolve(current: buffer.rows[0], rows: buffer.rows, currentIndex: 0)
        XCTAssertEqual(earlier?.source, "履歴0", "Old captures remain accessible independently")
    }

    func testPopupSemanticSentenceLookupWithMissingAnchorAndAdjacentGroups() {
        let capture = UUID(), semanticID = UUID()
        let left = Caption(captureID: capture, language: .japanese, source: "左", start: 0, end: 1, isFinal: true)
        var first = Caption(captureID: capture, language: .japanese, source: "甲", start: 1, end: 2, isFinal: true)
        first.semanticSentenceID = semanticID
        first.semanticSentenceAnchor = false
        first.semanticSentenceSource = "甲乙"
        var second = first; second.id = UUID(); second.source = "乙"
        let right = Caption(captureID: capture, language: .japanese, source: "右", start: 3, end: 4, isFinal: true)
        let rows = [left, first, second, right]
        let restored = PopupSemanticSentence.resolve(current: second, rows: rows, currentIndex: 2)
        XCTAssertEqual(restored?.id, semanticID)
        XCTAssertEqual(restored?.source, "甲乙")
        XCTAssertEqual(restored?.start, 1)
        XCTAssertEqual(PopupSemanticSentence.resolve(current: right, rows: rows, currentIndex: 3)?.source, "右")
        XCTAssertNil(PopupSemanticSentence.resolve(current: second, rows: rows, currentIndex: 10))
    }

    func testSeparationPreservesOneSemanticSentenceAcrossVisualRows() {
        let capture = UUID()
        let original = Caption(captureID: capture, language: .japanese, source: "前重後",
            translation: "기존 번역", start: 0, end: 10, isFinal: true, timedTextSpans: [
                .init(utf16Start: 0, utf16End: 1, start: 0, end: 4.9),
                .init(utf16Start: 1, utf16End: 2, start: 4.9, end: 5.1),
                .init(utf16Start: 2, utf16End: 3, start: 5.1, end: 10)
            ])
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [original]
        let target = OverlapEpisode(start: 4.9, end: 5.1)
        let a = Caption(captureID: UUID(), language: .japanese, source: "甲", start: 4.9, end: 5.1,
            isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 4.9, end: 5.1)], separationLane: 0)
        var b = a; b.source = "乙"; b.separationLane = 1
        let ids = buffer.applySeparation(original: original, target: target, separated: [a,b])
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(Set(buffer.rows.map(\.semanticID)), Set([original.id]))
        XCTAssertEqual(Set(buffer.rows.map(\.semanticSource)), Set(["前甲乙後"]))
        XCTAssertEqual(buffer.rows.filter(\.isSemanticSentenceAnchor).count, 1)
        XCTAssertEqual(buffer.rows.first?.id, original.id)
        XCTAssertEqual(Set(buffer.rows.map(\.contextGroup)).count, 1)
        // A word-selected visual lane must resolve to one full sentence when the
        // popup's "문장" action switches sentenceView on. Save must use that source.
        let fragment = buffer.rows[2]
        XCTAssertEqual(fragment.source, "乙")
        let sentence = try? XCTUnwrap(PopupSemanticSentence.resolve(current: fragment, rows: buffer.rows, currentIndex: 2))
        XCTAssertEqual(sentence?.source, "前甲乙後")
        XCTAssertEqual(sentence?.contextGroup, fragment.contextGroup)
        if let sentence {
            let payload = try? SavePayload.make(caption: sentence, session: .init(id: "test"),
                                                token: nil, tokens: [], translation: "test")
            XCTAssertEqual(payload?["source_text"] as? String, "前甲乙後")
            XCTAssertEqual(payload?["item_type"] as? String, "sentence_box")
        }
    }

    func testSeparationRejectsAppleRunThatStraddlesOverlapBoundary() {
        let capture = UUID()
        let original = Caption(captureID: capture, language: .japanese, source: "ABC", start: 0, end: 10,
            isFinal: true, timedTextSpans: [
                .init(utf16Start: 0, utf16End: 1, start: 0, end: 4.5),
                .init(utf16Start: 1, utf16End: 2, start: 4.5, end: 5.3),
                .init(utf16Start: 2, utf16End: 3, start: 5.3, end: 10)
            ])
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [original]
        let target = OverlapEpisode(start: 4.8, end: 5.1)
        let a = Caption(captureID: UUID(), language: .japanese, source: "甲", start: 4.8, end: 5.1,
            isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 4.8, end: 5.1)], separationLane: 0)
        var b = a; b.source = "乙"; b.separationLane = 1
        XCTAssertTrue(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty)
        XCTAssertEqual(buffer.rows.map(\.source), ["ABC"])
    }

    func testSeparationRejectsUntimedTextHoleBetweenSelectedRuns() {
        let capture = UUID()
        let original = Caption(captureID: capture, language: .japanese, source: "ABC", start: 0, end: 1,
            isFinal: true, timedTextSpans: [
                .init(utf16Start: 0, utf16End: 1, start: 0.4, end: 0.5),
                .init(utf16Start: 2, utf16End: 3, start: 0.5, end: 0.6)
            ])
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [original]
        let target = OverlapEpisode(start: 0.4, end: 0.6)
        let a = Caption(captureID: UUID(), language: .japanese, source: "甲", start: 0.4, end: 0.6,
            isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 0.4, end: 0.6)], separationLane: 0)
        var b = a; b.source = "乙"; b.separationLane = 1
        XCTAssertTrue(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty)
        XCTAssertEqual(buffer.rows.map(\.source), ["ABC"], "untimed B must never be deleted by min/max text cutting")
    }

    func testSeparationSlicesDeliveryTimeSpeakerMetadataNotStaleSnapshot() {
        let capture = UUID()
        let timed: [TimedTextSpan] = [
            .init(utf16Start: 0, utf16End: 1, start: 0, end: 0.4),
            .init(utf16Start: 1, utf16End: 2, start: 0.4, end: 0.6),
            .init(utf16Start: 2, utf16End: 3, start: 0.6, end: 1)
        ]
        let original = Caption(captureID: capture, language: .japanese, source: "ABC", start: 0, end: 1,
            isFinal: true, timedTextSpans: timed)
        var current = original
        current.speakerSpans = [
            .init(utf16Start: 0, utf16End: 1, start: 0, end: 0.4, speaker: 7, confidentSpeech: 0.4, overlap: false),
            .init(utf16Start: 2, utf16End: 3, start: 0.6, end: 1, speaker: 7, confidentSpeech: 0.4, overlap: false)
        ]
        current.speaker = 7
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [current]
        let target = OverlapEpisode(start: 0.4, end: 0.6)
        let a = Caption(captureID: UUID(), language: .japanese, source: "甲", start: 0.4, end: 0.6,
            isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 0.4, end: 0.6)], separationLane: 0)
        var b = a; b.source = "乙"; b.separationLane = 1
        XCTAssertFalse(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty)
        XCTAssertEqual(buffer.rows.first?.speakerSpans.first?.speaker, 7)
        XCTAssertEqual(buffer.rows.last?.speakerSpans.first?.speaker, 7)
    }

    func testSeparationNeverLeavesPunctuationOnlySuffixCaption() {
        let capture = UUID()
        let original = Caption(captureID: capture, language: .japanese, source: "AB。", start: 0, end: 1,
            isFinal: true, timedTextSpans: [
                .init(utf16Start: 0, utf16End: 1, start: 0, end: 0.4),
                .init(utf16Start: 1, utf16End: 2, start: 0.4, end: 0.6)
            ])
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [original]
        let target = OverlapEpisode(start: 0.4, end: 0.6)
        let a = Caption(captureID: UUID(), language: .japanese, source: "甲", start: 0.4, end: 0.6,
            isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 0.4, end: 0.6)], separationLane: 0)
        var b = a; b.source = "乙"; b.separationLane = 1
        XCTAssertFalse(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty)
        XCTAssertEqual(buffer.rows.map(\.source), ["A", "甲", "乙。"])
        XCTAssertFalse(buffer.rows.contains { !$0.source.isEmpty && !SentenceBoundary.hasSemanticContent($0.source) })
    }

    func testSeparationRejectsStaleClearOutOfRangeAndUntimedPrimary() {
        let capture = UUID()
        var original = Caption(captureID: capture, language: .japanese, source: "元文", start: 0, end: 1, isFinal: true)
        var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese)
        buffer.rows = [original]
        let target = OverlapEpisode(start: 0.4, end: 0.7)
        var a = Caption(captureID: UUID(), language: .japanese, source: "甲", start: 0.4, end: 0.7,
            isFinal: true, timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 0.4, end: 0.7)], separationLane: 0)
        var b = a; b.source = "乙"; b.separationLane = 1
        XCTAssertTrue(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty,
                      "without Apple timed text the app must preserve Primary rather than guess a character cut")
        original.timedTextSpans = [
            .init(utf16Start: 0, utf16End: 1, start: 0, end: 0.5),
            .init(utf16Start: 1, utf16End: 2, start: 0.5, end: 1)
        ]
        buffer.rows = [original]
        b.end = 1.5
        XCTAssertTrue(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty)
        b.end = 0.7
        buffer.rows[0].source = "変更"
        XCTAssertTrue(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty)
        buffer.clearDisplay(through: 1)
        XCTAssertTrue(buffer.applySeparation(original: original, target: target, separated: [a,b]).isEmpty)
        XCTAssertTrue(buffer.rows.isEmpty)
    }

    func testSeparationAcceptanceRequiresTwoVoicedDistinctLanes() throws {
        let target = SeparationTarget(episode: .init(start: 1, end: 1.5), inferenceStart: 0, inferenceEnd: 2)
        func row(_ text: String, lane: Int) -> Caption {
            Caption(captureID: UUID(), language: .japanese, source: text, start: 1, end: 1.5, isFinal: true,
                timedTextSpans: [.init(utf16Start: 0, utf16End: text.utf16.count, start: 1, end: 1.5)],
                separationLane: lane)
        }
        let frames = [[StemSpeechFrame(start: 1, end: 1.5, probability: 0.9)],
                      [StemSpeechFrame(start: 1, end: 1.5, probability: 0.9)]]
        XCTAssertThrowsError(try SeparationAcceptance.accepted(
            .init(rows: [row("同じ", lane: 0), row("同じ", lane: 1)], speechFrames: frames), target: target))
        let accepted = try SeparationAcceptance.accepted(
            .init(rows: [row("甲です", lane: 0), row("乙だよ", lane: 1)], speechFrames: frames), target: target)
        XCTAssertEqual(Set(accepted.compactMap(\.separationLane)), Set([0,1]))
        XCTAssertThrowsError(try SeparationAcceptance.accepted(
            .init(rows: [row("甲です", lane: 0), row("乙だよ", lane: 1)],
                  speechFrames: [frames[0], [StemSpeechFrame(start: 1, end: 1.5, probability: 0.1)]]), target: target))
    }

    func testSeparationAcceptanceRejectsPartiallyIntersectingStemTimingRun() {
        let target = SeparationTarget(episode: .init(start: 1, end: 1.3), inferenceStart: 0, inferenceEnd: 2)
        func row(_ text: String, lane: Int) -> Caption {
            Caption(captureID: UUID(), language: .japanese, source: text, start: 0.8, end: 1.5, isFinal: true,
                timedTextSpans: [.init(utf16Start: 0, utf16End: text.utf16.count, start: 0.8, end: 1.5)],
                separationLane: lane)
        }
        let frames = [[StemSpeechFrame(start: 1, end: 1.3, probability: 0.9)],
                      [StemSpeechFrame(start: 1, end: 1.3, probability: 0.9)]]
        XCTAssertThrowsError(try SeparationAcceptance.accepted(
            .init(rows: [row("甲です", lane: 0), row("乙です", lane: 1)], speechFrames: frames), target: target))
    }

    func testSeparationAcceptanceRequiresVADTextCoevidenceAndSimultaneousSupport() {
        let target = SeparationTarget(episode: .init(start: 1, end: 1.8), inferenceStart: 0, inferenceEnd: 2)
        func row(_ text: String, lane: Int, start: Double, end: Double) -> Caption {
            Caption(captureID: UUID(), language: .japanese, source: text, start: start, end: end, isFinal: true,
                timedTextSpans: [.init(utf16Start: 0, utf16End: text.utf16.count, start: start, end: end)],
                separationLane: lane)
        }
        // VAD exists for each lane, but not where that lane's text is timed.
        XCTAssertThrowsError(try SeparationAcceptance.accepted(.init(rows: [
            row("甲", lane: 0, start: 1.4, end: 1.7), row("乙", lane: 1, start: 1.0, end: 1.3)
        ], speechFrames: [
            [StemSpeechFrame(start: 1.0, end: 1.3, probability: 0.95)],
            [StemSpeechFrame(start: 1.4, end: 1.7, probability: 0.95)]
        ]), target: target))

        // Each lane has valid VAD+text support, but they are purely sequential rather
        // than simultaneous. This must not validate a two-speaker overlap replacement.
        XCTAssertThrowsError(try SeparationAcceptance.accepted(.init(rows: [
            row("甲", lane: 0, start: 1.0, end: 1.3), row("乙", lane: 1, start: 1.5, end: 1.8)
        ], speechFrames: [
            [StemSpeechFrame(start: 1.0, end: 1.3, probability: 0.95)],
            [StemSpeechFrame(start: 1.5, end: 1.8, probability: 0.95)]
        ]), target: target))
    }

    func testSeparatorLaneMapsToGlobalSpeakerOnlyFromNonOverlapAnchors() {
        let episode = OverlapEpisode(start: 1, end: 1.5)
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0.5, end: 0.9, speakerSlot: 7),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 0.9, end: 1.6),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 1.6, end: 2.0, speakerSlot: 9)
        ])
        let left = Caption(captureID: UUID(), language: .japanese, source: "前", start: 0.5, end: 0.9, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 0.5, end: 0.9)], separationLane: 0)
        let right = Caption(captureID: UUID(), language: .japanese, source: "後", start: 1.6, end: 2.0, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 1.6, end: 2.0)], separationLane: 1)
        let speechFrames = [
            [StemSpeechFrame(start: 0.5, end: 0.9, probability: 0.95), StemSpeechFrame(start: 1.6, end: 2.0, probability: 0.05)],
            [StemSpeechFrame(start: 0.5, end: 0.9, probability: 0.05), StemSpeechFrame(start: 1.6, end: 2.0, probability: 0.95)]
        ]
        XCTAssertEqual(SeparationLaneMapper.mapping(rows: [left,right], speechFrames: speechFrames,
            episode: episode, timeline: timeline),
            [0: LaneSpeakerIdentity(epoch: 0, slot: 7), 1: LaneSpeakerIdentity(epoch: 0, slot: 9)])
        let unresolved = SeparationLaneMapper.applying([:], to: [left,right])
        XCTAssertTrue(unresolved.allSatisfy { $0.speaker == nil })
    }

    func testR5GMapperRequiresOverlapEpochAndPersistsItInSpans() {
        let episode = OverlapEpisode(start: 1, end: 1.5)
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0.5, end: 0.9,
                  speakerSlot: 0, identityEpoch: 10),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 0.9, end: 1.6,
                  identityEpoch: 11),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 1.6, end: 2.0,
                  speakerSlot: 0, identityEpoch: 11)
        ])
        let older = Caption(captureID: UUID(), language: .japanese, source: "前", start: 0.5,
            end: 0.9, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 0.5, end: 0.9)], separationLane: 0)
        let latest = Caption(captureID: UUID(), language: .japanese, source: "後", start: 1.6,
            end: 2.0, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: 1, start: 1.6, end: 2.0)], separationLane: 0)
        let vad: [[StemSpeechFrame]] = [
            [.init(start: 0.5, end: 0.9, probability: 0.95),
             .init(start: 1.6, end: 2.0, probability: 0.95)],
            [.init(start: 0.5, end: 0.9, probability: 0.01),
             .init(start: 1.6, end: 2.0, probability: 0.01)]
        ]
        XCTAssertTrue(SeparationLaneMapper.mapping(rows: [older], speechFrames: vad,
            episode: episode, timeline: timeline).isEmpty,
            "Old epoch evidence must not assign a speaker to a later overlap")
        let accepted = SeparationLaneMapper.mapping(rows: [older, latest], speechFrames: vad,
            episode: episode, timeline: timeline)
        XCTAssertEqual(accepted[0], LaneSpeakerIdentity(epoch: 11, slot: 0))
        let painted = SeparationLaneMapper.applying(accepted, to: [latest])
        XCTAssertEqual(painted.first?.speakerSpans.first?.identityEpoch, 11)
    }

    func testSeparatorLaneMappingRejectsCrosstalkWithoutStemDominance() {
        let episode = OverlapEpisode(start: 1, end: 1.5)
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0.5, end: 0.9, speakerSlot: 7),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 1, end: 1.5)
        ])
        let row = Caption(captureID: UUID(), language: .japanese, source: "漏れ", start: 0.5, end: 0.9, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: 2, start: 0.5, end: 0.9)], separationLane: 0)
        let frames = [
            [StemSpeechFrame(start: 0.5, end: 0.9, probability: 0.8)],
            [StemSpeechFrame(start: 0.5, end: 0.9, probability: 0.75)]
        ]
        XCTAssertTrue(SeparationLaneMapper.mapping(rows: [row], speechFrames: frames,
            episode: episode, timeline: timeline).isEmpty)
    }

    func testLiveOverlapRequiresClosureButEOFAcceptsOpenTail() {
        var timeline = SpeechTimeline()
        timeline.append((0..<3).map { .init(speechProbability: 0.95, activeSpeakers: 2,
            start: Double($0)*0.1, end: Double($0+1)*0.1) })
        XCTAssertTrue(timeline.overlapEpisodes(start: 0, end: 0.3).isEmpty,
                      "live capture must not schedule an overlap whose end was never observed")
        let eof = timeline.overlapEpisodes(start: 0, end: 0.3, includeOpenTail: true)
        XCTAssertEqual(eof, [OverlapEpisode(start: 0, end: 0.3)])
    }

    func testGlobalOverlapDurationSurvivesSemanticSentenceBoundary() {
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0.7, end: 0.8, speakerSlot: 0),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 0.8, end: 0.9),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 0.9, end: 1.0),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 1.0, end: 1.1),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 1.1, end: 1.2),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 1.2, end: 1.3, speakerSlot: 0)
        ])
        let global = timeline.overlapEpisodes(start: 0, end: 2)
        XCTAssertEqual(global, [OverlapEpisode(start: 0.8, end: 1.2)])
        XCTAssertLessThan(1.0-global[0].start, 0.28)
        XCTAssertLessThan(global[0].end-1.0, 0.28)
        XCTAssertGreaterThanOrEqual(global[0].duration, 0.28,
            "duration gate belongs to the global episode, not each sentence fragment")
    }

    @MainActor
    func testLiveSeparationTargetsOnlyStableOverlapEpisodeNotWholeCaption() {
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0, end: 0.2, speakerSlot: 0),
            // Deliberate unrelated diarization gap before the overlap.
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 4.8, end: 4.9),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 4.9, end: 5.0),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 5.0, end: 5.1),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 5.1, end: 5.4, speakerSlot: 0),
            .init(speechProbability: 0.95, activeSpeakers: 3, start: 9.9, end: 10.0)
        ])
        let row = Caption(captureID: UUID(), language: .japanese, source: "長い会話。", start: 0, end: 10, isFinal: true,
            timedTextSpans: [
                .init(utf16Start: 0, utf16End: 1, start: 0, end: 4.8),
                .init(utf16Start: 1, utf16End: 2, start: 4.8, end: 5.1),
                .init(utf16Start: 2, utf16End: "長い会話。".utf16.count, start: 5.1, end: 10)
            ])
        let episodes = timeline.overlapEpisodes(start: 0, end: 10)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].start, 4.8, accuracy: 0.0001)
        XCTAssertEqual(episodes[0].end, 5.1, accuracy: 0.0001)
        let target = LiveSeparationPass.target(for: row, timeline: timeline)
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.episode, episodes[0])
        XCTAssertLessThanOrEqual((target?.inferenceEnd ?? 100)-(target?.inferenceStart ?? 0), 4.0001,
                                 "300 ms overlap must not turn a 10 s Primary row into a full-row rewrite")
        XCTAssertTrue(LiveSeparationPass.eligible(row, timeline: timeline))
    }

    @MainActor
    func testShortOverlapRejectsCoarseWholePhraseTimingBeforeSeparatorWork() {
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 4.8, end: 4.9),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 4.9, end: 5.0),
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 5.0, end: 5.1)
        ])
        let text = "이 테스트는 실제로 일본어 문자열이 아니어도 timing 정책만 확인합니다."
        let row = Caption(captureID: UUID(), language: .japanese, source: text, start: 0, end: 10, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: text.utf16.count, start: 0, end: 10)])
        XCTAssertNil(LiveSeparationPass.target(for: row, timeline: timeline),
                     "coarse whole-phrase timing must preserve Primary instead of guessing a 300 ms character cut")
    }

    @MainActor
    func testMissingSeparationModelNeverClaimsWorkOrDeliversRows() {
        var timeline = SpeechTimeline()
        timeline.append((0..<3).map { .init(speechProbability: 0.9, activeSpeakers: 2,
            start: Double($0)*0.1, end: Double($0+1)*0.1) })
        let row = Caption(captureID: UUID(), language: .japanese, source: "会話。", start: 0, end: 0.3, isFinal: true)
        let pass = LiveSeparationPass(modelURL: nil, currentRows: { [row] }, currentTimeline: { timeline },
            deliver: { _, _, _ in XCTFail("Missing models must not produce separation output"); return [] },
            remap: { _, _ in XCTFail("Missing models must not remap") })
        pass.consider(fastBacklog: 0)
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
    func testR5CWholeSessionAuditRetainsEarlyFailurePastFortyEightCallbacks() {
        var audit = DeviceValidationSpeechAudit()
        audit.record(text: "甲", final: true, timedSpans: [])
        for _ in 0..<55 {
            audit.record(text: "乙", final: true,
                timedSpans: [.init(utf16Start: 0, utf16End: 1, start: 0, end: 1)])
        }
        XCTAssertEqual(audit.callbackCount, 56)
        XCTAssertEqual(audit.recognizedCount, 56)
        XCTAssertEqual(audit.invalidTimedCount, 1)
        XCTAssertFalse(audit.timedIntegrityPassed)
        XCTAssertEqual(audit.invalidExamples.count, 1)
        var punctuationOnly = DeviceValidationSpeechAudit()
        punctuationOnly.record(text: "。", final: true, timedSpans: [])
        punctuationOnly.record(text: "", final: false, timedSpans: [])
        XCTAssertEqual(punctuationOnly.callbackCount, 2)
        XCTAssertEqual(punctuationOnly.recognizedCount, 0)
        XCTAssertFalse(punctuationOnly.timedIntegrityPassed)
    }

    func testR5CDeviceValidationTimedSpeechInvariants() {
        let good = [TimedTextSpan(utf16Start: 0, utf16End: 1, start: 0, end: 1),
                    TimedTextSpan(utf16Start: 1, utf16End: 2, start: 1, end: 2)]
        XCTAssertTrue(DeviceValidationInvariants.hasRecognizedContent("日本語の会話"))
        XCTAssertTrue(DeviceValidationInvariants.hasRecognizedContent("English 123"))
        XCTAssertFalse(DeviceValidationInvariants.hasRecognizedContent("。！？"))
        XCTAssertFalse(DeviceValidationInvariants.hasRecognizedContent("  "))
        XCTAssertTrue(DeviceValidationInvariants.validTimedSpeech(text: "甲乙", spans: good))
        XCTAssertFalse(DeviceValidationInvariants.validTimedSpeech(text: "甲乙", spans: []))
        XCTAssertFalse(DeviceValidationInvariants.validTimedSpeech(text: "甲乙", spans: [good[0]]))
        let backward = [TimedTextSpan(utf16Start: 0, utf16End: 1, start: 4, end: 5),
                        TimedTextSpan(utf16Start: 1, utf16End: 2, start: 1, end: 2)]
        XCTAssertFalse(DeviceValidationInvariants.validTimedSpeech(text: "甲乙", spans: backward))
        let reordered = [good[1], good[0]]
        XCTAssertFalse(DeviceValidationInvariants.validTimedSpeech(text: "甲乙", spans: reordered))
        let emoji = [TimedTextSpan(utf16Start: 0, utf16End: 2, start: 0, end: 1),
                     TimedTextSpan(utf16Start: 2, utf16End: 3, start: 1, end: 2)]
        XCTAssertTrue(DeviceValidationInvariants.validTimedSpeech(text: "🎮乙", spans: emoji))
        let earlier = Date(timeIntervalSince1970: 10)
        let later = Date(timeIntervalSince1970: 11)
        XCTAssertTrue(DeviceValidationInvariants.explicitStopRestart(
            firstStopped: true, secondStopped: true, firstEnd: earlier, secondStart: later))
        XCTAssertFalse(DeviceValidationInvariants.explicitStopRestart(
            firstStopped: false, secondStopped: true, firstEnd: earlier, secondStart: later))
        XCTAssertFalse(DeviceValidationInvariants.explicitStopRestart(
            firstStopped: true, secondStopped: false, firstEnd: earlier, secondStart: later))
        XCTAssertFalse(DeviceValidationInvariants.explicitStopRestart(
            firstStopped: true, secondStopped: true, firstEnd: later, secondStart: earlier))
    }

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
        metrics.recordSpeechResult(text: "正常。", final: true, start: 0, end: 10,
                                   finalizedThrough: 10,
                                   timedSpans: [.init(utf16Start: 0, utf16End: "正常。".utf16.count,
                                                      start: 0, end: 10)], observedAt: 10.5)

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
    func testR5IDeviceValidationNativeStopFailureCannotPassSession() {
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
        metrics.recordSpeechResult(text: "正常。", final: true, start: 0, end: 10,
                                   finalizedThrough: 10,
                                   timedSpans: [.init(utf16Start: 0, utf16End: "正常。".utf16.count,
                                                      start: 0, end: 10)], observedAt: 10.5)
        metrics.recordNativeStopFailure(nil)
        metrics.recordNativeStopFailure("   ")
        XCTAssertEqual(metrics.finish(userStopped: true, endedAt: Date(timeIntervalSince1970: 10), endedUptime: 20).verdict, .pass)

        let stopError = "SCStream.stopCapture failed"
        metrics.recordNativeStopFailure(stopError)
        metrics.recordNativeStopFailure(stopError) // concurrent/coalesced stop must not duplicate errors
        let failed = metrics.finish(userStopped: true, endedAt: Date(timeIntervalSince1970: 10), endedUptime: 20)
        XCTAssertEqual(failed.verdict, .fail)
        XCTAssertEqual(failed.errors, ["네이티브 종료 확인 실패: " + stopError])
        XCTAssertTrue(failed.checks.contains {
            $0.name == "runtime_errors" && $0.verdict == .fail && $0.detail.contains(stopError)
        })
    }

    @MainActor
    func testDeviceValidationTwoSpeakerProbeRecordsRawTextDiarizationAndRequiredSeparator() {
        let metrics = DeviceValidationMetricStore(startedAt: Date(timeIntervalSince1970: 0), startedUptime: 10,
                                                  requireTwoSpeakerProbe: true)
        metrics.recordSeparatorModelBundled(true)
        metrics.recordDiarizerModelBundled(true)
        metrics.recordSpeechResult(text: "二人の会話です。", final: true, start: 0, end: 1, finalizedThrough: 1,
                                   timedSpans: [.init(utf16Start: 0, utf16End: "二人の会話です。".utf16.count,
                                                      start: 0, end: 1)], observedAt: 10.5)
        metrics.recordDiarization([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0, end: 0.5, speakerSlot: 0),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0.5, end: 1, speakerSlot: 2)
        ])
        let report = metrics.finish(userStopped: true, endedAt: Date(timeIntervalSince1970: 1), endedUptime: 11)
        XCTAssertEqual(report.speechTrace.last?.text, "二人の会話です。")
        XCTAssertEqual(report.diarization.distinctSpeakerSlots, [0, 2])
        XCTAssertTrue(report.separatorModelBundled)
        XCTAssertTrue(report.diarizerModelBundled)
        XCTAssertTrue(report.checks.contains { $0.name == "live_diarization" && $0.verdict == .pass })
        XCTAssertTrue(report.checks.contains { $0.name == "two_speaker_slots" && $0.verdict == .pass })
        XCTAssertTrue(report.checks.contains { $0.name == "overlap_detected" && $0.verdict == .warning })
        XCTAssertTrue(report.checks.contains { $0.name == "diarizer_model_bundled" && $0.verdict == .pass })
        XCTAssertTrue(report.checks.contains { $0.name == "separator_model_bundled" && $0.verdict == .pass })
    }

    func testR5CDeviceValidationLateReadyEOFMakesFinalHandoff() async throws {
        let pipeline = AudioPreprocessor()
        let (primary, _) = try await pipeline.process(Self.pcm(count: 4800, time: 0, amplitude: 0.2))
        XCTAssertFalse(primary.isEmpty)
        let provider = OptionalProviderPreparation()
        await provider.start(analysis: { PatternAnalysis() }, enhancement: nil)
        // Deterministic mock loader only. Product Device Validation performs
        // a nonwaiting takeReady at EOF, not waitUntilFinished on a native model.
        await provider.waitUntilFinished()
        let lateReady = await provider.takeReady()
        XCTAssertNotNil(lateReady.analysis, "Ready model must still be in mailbox at natural EOF")
        await pipeline.installPrepared(analysis: lateReady.analysis, enhancement: nil)
        await provider.cancel()
        _ = try await pipeline.finish(cancelAnalysis: false)
        let updates = await pipeline.takeAnalysisUpdates()
        XCTAssertFalse(updates.isEmpty, "EOF-installed analysis should backfill retained source PCM")
        XCTAssertTrue(updates.contains { $0.start <= 0.00001 })
    }

    @MainActor
    func testR5COldInvalidSTTNeverEvictedFromSessionIntegrity() {
        let metrics = DeviceValidationMetricStore()
        metrics.recordSpeechResult(text: "甲", final: true, start: 0, end: 1,
                                   finalizedThrough: 1, timedSpans: [])
        for i in 1...55 {
            metrics.recordSpeechResult(text: "乙", final: true, start: Double(i), end: Double(i+1),
                finalizedThrough: Double(i+1), timedSpans: [
                    .init(utf16Start: 0, utf16End: 1, start: Double(i), end: Double(i+1))])
        }
        let report = metrics.finish(userStopped: true)
        XCTAssertEqual(report.speechTrace.count, 48)
        XCTAssertEqual(report.semanticSpeechResults, 56)
        XCTAssertEqual(report.invalidTimedSpeechResults, 1)
        XCTAssertTrue(report.speechTrace.allSatisfy { !$0.timedSpans.isEmpty })
        XCTAssertTrue(report.checks.contains { $0.name == "speech_timed_span_integrity" && $0.verdict == .fail })
        XCTAssertEqual(report.verdict, .fail)
    }

    @MainActor
    func testR5CReversedTimedSpeechFailsEvenWithContinuousUTF16() {
        let metrics = DeviceValidationMetricStore()
        metrics.recordSpeechResult(text: "甲乙", final: true, start: 0, end: 5,
            finalizedThrough: 5, timedSpans: [
                .init(utf16Start: 0, utf16End: 1, start: 4, end: 5),
                .init(utf16Start: 1, utf16End: 2, start: 1, end: 2)])
        let report = metrics.finish(userStopped: true)
        XCTAssertEqual(report.invalidTimedSpeechResults, 1)
        XCTAssertTrue(report.checks.contains { $0.name == "speech_timed_span_integrity" && $0.verdict == .fail })
    }

    @MainActor
    func testR5COnlyEmptySTTCallbacksCannotPassSession() {
        let metrics = DeviceValidationMetricStore()
        for _ in 0..<10 { metrics.recordSpeechResult(final: true) }
        metrics.recordSpeechResult(text: "。！？", final: true, start: 0, end: 1, finalizedThrough: 1)
        let report = metrics.finish(userStopped: true)
        XCTAssertEqual(report.speechResults, 11)
        XCTAssertEqual(report.semanticSpeechResults, 0)
        XCTAssertTrue(report.checks.contains { $0.name == "speech_results" && $0.verdict == .warning })
        XCTAssertTrue(report.checks.contains { $0.name == "speech_timed_span_integrity" && $0.verdict == .warning })
        XCTAssertNotEqual(report.verdict, .pass)
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
        func session(start: Double, wallStart: Double, userStopped: Bool = true,
                     includesText: Bool = true) -> DeviceValidationSessionReport {
            let metrics = DeviceValidationMetricStore(startedAt: Date(timeIntervalSince1970: wallStart), startedUptime: 30)
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
            if includesText {
                metrics.recordSpeechResult(text: "甲", final: true, start: start, end: start+10,
                    finalizedThrough: start+10,
                    timedSpans: [.init(utf16Start: 0, utf16End: 1, start: start, end: start+10)],
                    observedAt: 30.5)
            } else {
                metrics.recordSpeechResult(final: true, observedAt: 30.5)
            }
            return metrics.finish(userStopped: userStopped,
                                  endedAt: Date(timeIntervalSince1970: wallStart+10), endedUptime: 40)
        }

        let clean = DeviceValidationReport.make(sessions: [session(start: 0, wallStart: 0), session(start: 0, wallStart: 11)])
        XCTAssertEqual(clean.restartCheck.verdict, .pass)
        let stale = DeviceValidationReport.make(sessions: [session(start: 0, wallStart: 0), session(start: 10, wallStart: 11)])
        XCTAssertEqual(stale.restartCheck.verdict, .fail)
        let naturalEOF = DeviceValidationReport.make(sessions: [
            session(start: 0, wallStart: 0, userStopped: false), session(start: 0, wallStart: 11, userStopped: false)])
        XCTAssertEqual(naturalEOF.restartCheck.verdict, .fail)
        let secondNotStopped = DeviceValidationReport.make(sessions: [
            session(start: 0, wallStart: 0), session(start: 0, wallStart: 11, userStopped: false)])
        XCTAssertEqual(secondNotStopped.restartCheck.verdict, .fail)
        let outOfOrder = DeviceValidationReport.make(sessions: [
            session(start: 0, wallStart: 11), session(start: 0, wallStart: 0)])
        XCTAssertEqual(outOfOrder.restartCheck.verdict, .fail)
        let emptySTT = DeviceValidationReport.make(sessions: [
            session(start: 0, wallStart: 0), session(start: 0, wallStart: 11, includesText: false)])
        XCTAssertEqual(emptySTT.restartCheck.verdict, .fail)
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
    func testCommittedSentencePrefixKeepsItsSpeakerWhenNextSpeakerAlreadyEnteredRollingBuffer() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        XCTAssertTrue(buffer.receive("今日は", final: true, start: 0, end: 1, speaker: 0, now: 0).isEmpty)
        let ready = buffer.receive("。次", final: true, start: 1, end: 2, speaker: 1, now: 0.1)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(buffer.rows[0].source, "今日は。")
        XCTAssertTrue(buffer.rows[0].isFinal)
        XCTAssertEqual(buffer.rows[0].speaker, 0)
        XCTAssertEqual(buffer.rows.last?.source, "次")
        XCTAssertFalse(buffer.rows.last?.isFinal ?? true)
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


    func testLateSpeakerTimelineCanAttributeCaptionAcrossInternalSilence() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("昨日ゲームをした", final: true, start: 0, end: 1, speaker: nil, now: 0)
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0, end: 0.4, speakerSlot: 2),
            .init(speechProbability: 0.05, activeSpeakers: 0, start: 0.4, end: 0.6),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0.6, end: 1, speakerSlot: 2)
        ])
        let changed = buffer.applySpeakerTimeline(timeline)
        XCTAssertEqual(changed, [buffer.rows[0].id])
        XCTAssertEqual(buffer.rows[0].speaker, 2)
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





    @MainActor


    @MainActor


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

    func testSpeakerTimelineMarksSequentialTurnOrOverlapAsMixedWithoutForcingSentenceSplit() {
        var sequential = SpeechTimeline()
        sequential.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0, end: 0.5, speakerSlot: 1),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0.5, end: 1, speakerSlot: 4)
        ])
        XCTAssertNil(sequential.speaker(start: 0, end: 1))
        XCTAssertTrue(sequential.hasMultipleSpeakersOrOverlap(start: 0, end: 1))

        var overlap = SpeechTimeline()
        overlap.append([
            .init(speechProbability: 0.95, activeSpeakers: 2, start: 0, end: 1)
        ])
        XCTAssertNil(overlap.speaker(start: 0, end: 1))
        XCTAssertTrue(overlap.hasMultipleSpeakersOrOverlap(start: 0, end: 1))

        var silence = SpeechTimeline()
        silence.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0, end: 0.4, speakerSlot: 1),
            .init(speechProbability: 0.05, activeSpeakers: 0, start: 0.4, end: 0.6),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0.6, end: 1, speakerSlot: 1)
        ])
        XCTAssertFalse(silence.hasMultipleSpeakersOrOverlap(start: 0, end: 1))
    }

    func testSourceTimeFallbackUsesConsumedPrefixEvenAfterStableMutation() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("甲。乙", final: true, start: 5, end: 8, speaker: nil, now: 8)
        XCTAssertEqual(buffer.rows.first?.source, "甲。")
        XCTAssertEqual(buffer.rows.first?.start ?? -1, 5, accuracy: 0.000001)
        XCTAssertGreaterThan(buffer.rows.first?.end ?? 0, 5)
        _ = buffer.finish()
        XCTAssertEqual(buffer.rows.map(\.source), ["甲。", "乙"])
        XCTAssertGreaterThanOrEqual(buffer.rows[1].start, 5)
        XCTAssertLessThanOrEqual(buffer.rows[1].end, 8)

        var noRemainder = TranscriptBuffer()
        noRemainder.begin(captureID: UUID(), language: .japanese)
        _ = noRemainder.receive("甲。", final: true, start: 5, end: 6, speaker: nil, now: 6)
        XCTAssertEqual(noRemainder.rows.first?.start ?? -1, 5, accuracy: 0.000001)
        XCTAssertEqual(noRemainder.rows.first?.end ?? -1, 6, accuracy: 0.000001)
    }

    func testPunctuationFinalOverlappingVolatileBelongsToNewestPhrase() {
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("甲", final: true, start: 0, end: 1, speaker: nil, now: 1)
        _ = buffer.receive("乙", final: false, start: 1, end: 2, speaker: nil, now: 2)
        _ = buffer.receive("。", final: true, start: 1, end: 2, speaker: nil, now: 2.1)
        XCTAssertEqual(buffer.rows.map(\.source), ["甲乙。"])
        XCTAssertTrue(buffer.rows.allSatisfy(\.isFinal))

        // Disjoint punctuation must still follow already finalized text.
        var disjoint = TranscriptBuffer()
        disjoint.begin(captureID: UUID(), language: .japanese)
        _ = disjoint.receive("甲乙", final: true, start: 0, end: 2, speaker: nil, now: 2)
        _ = disjoint.receive("。", final: true, start: 2, end: 2.1, speaker: nil, now: 2.1)
        XCTAssertEqual(disjoint.rows.first?.source, "甲乙。")
    }

    func testSeparationClipRebasesSpansAfterWhitespaceTrim() {
        let capture = UUID()
        let episode = OverlapEpisode(start: 1, end: 2)
        let row = Caption(captureID: capture, language: .japanese,
            source: " 乙 ", start: 1, end: 2, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: 3, start: 1, end: 2)], separationLane: 0)
        let clipped = SeparationAcceptance.clipped([row], to: episode)
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(clipped[0].source, "乙")
        XCTAssertEqual(clipped[0].timedTextSpans.map(\.utf16Start), [0])
        XCTAssertEqual(clipped[0].timedTextSpans.map(\.utf16End), [1])

        // UTF-16 rather than Character-count rebasing: emoji occupies two code units.
        let emoji = Caption(captureID: capture, language: .japanese,
            source: " 🍎甲 ", start: 1, end: 2, isFinal: true,
            timedTextSpans: [.init(utf16Start: 0, utf16End: 5, start: 1, end: 2)], separationLane: 1)
        let clippedEmoji = SeparationAcceptance.clipped([emoji], to: episode)
        XCTAssertEqual(clippedEmoji.first?.source, "🍎甲")
        XCTAssertEqual(clippedEmoji.first?.timedTextSpans.first?.utf16Start, 0)
        XCTAssertEqual(clippedEmoji.first?.timedTextSpans.first?.utf16End, 3)
    }

    @MainActor
    func testPrimaryQueuePunctuationFinalOverlappingPresentedVolatile() async {
        let model = AppModel()
        defer { model.clearTranscript() }
        model.receivePrimarySpeech(.init(text: "甲", final: true, start: 0, end: 1), language: .japanese)
        model.receivePrimarySpeech(.init(text: "乙", final: false, start: 1, end: 2), language: .japanese)
        try? await Task.sleep(for: .milliseconds(220))
        model.receivePrimarySpeech(.init(text: "。", final: true, start: 1, end: 2), language: .japanese)
        XCTAssertEqual(model.captions.map(\.source), ["甲乙。"])
        XCTAssertTrue(model.captions.allSatisfy(\.isFinal))
    }

    func testPunctuationOnlyFinalPreservesWholeMultiCharacterSuffix() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        _ = buffer.receive("今日は", final: true, start: 0, end: 1, speaker: nil, now: 0)
        _ = buffer.receive("。」", final: true, start: 1, end: 1.1, speaker: nil, now: 0.1)
        XCTAssertEqual(buffer.rows.first?.source, "今日は。」")
        XCTAssertTrue(buffer.rows.first?.isFinal == true)
    }

    func testOneAppleTimingRunAcrossTwoSentencesSurvivesOnBothRows() {
        var buffer = TranscriptBuffer(); buffer.begin(captureID: UUID(), language: .japanese)
        let all = TimedTextSpan(utf16Start: 0, utf16End: 4, start: 0, end: 4)
        _ = buffer.receive("甲。乙。", final: true, start: 0, end: 4, speaker: nil, now: 4, timedSpans: [all])
        XCTAssertEqual(buffer.rows.map(\.source), ["甲。", "乙。"])
        XCTAssertEqual(buffer.rows[0].timedTextSpans.count, 1)
        XCTAssertEqual(buffer.rows[1].timedTextSpans.count, 1)
        XCTAssertEqual(buffer.rows[0].timedTextSpans[0].start, 0, accuracy: 0.000001)
        XCTAssertEqual(buffer.rows[0].timedTextSpans[0].end, 4, accuracy: 0.000001)
        XCTAssertEqual(buffer.rows[1].timedTextSpans[0].start, 0, accuracy: 0.000001)
        XCTAssertEqual(buffer.rows[1].timedTextSpans[0].end, 4, accuracy: 0.000001)
        XCTAssertGreaterThan(buffer.rows[1].end-buffer.rows[1].start, 0)
    }

    func testTimedSpeechRunsDriveExactTokenizerBoundaryInsteadOfCharacterRatio() {
        let capture = UUID()
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: capture, language: .japanese)
        let spans = [
            TimedTextSpan(utf16Start: 0, utf16End: 2, start: 0, end: 3),
            TimedTextSpan(utf16Start: 2, utf16End: 3, start: 3, end: 4)
        ]
        let ready = buffer.receive("甲。乙", final: true, start: 0, end: 4,
                                   speaker: nil, now: 4, timedSpans: spans)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(buffer.rows.first?.source, "甲。")
        XCTAssertEqual(buffer.rows.first?.end ?? -1, 3, accuracy: 0.000001)
        XCTAssertEqual(buffer.rows.first?.timedTextSpans,
                       [TimedTextSpan(utf16Start: 0, utf16End: 2, start: 0, end: 3)])

        _ = buffer.finish()
        XCTAssertEqual(buffer.rows.count, 2)
        XCTAssertEqual(buffer.rows[1].source, "乙")
        XCTAssertEqual(buffer.rows[1].start, 3, accuracy: 0.000001)
        XCTAssertEqual(buffer.rows[1].timedTextSpans,
                       [TimedTextSpan(utf16Start: 0, utf16End: 1, start: 3, end: 4)])
    }

    func testOneSemanticSentenceRetainsPerTextSpeakerSpans() {
        let capture = UUID()
        var buffer = TranscriptBuffer()
        buffer.begin(captureID: capture, language: .japanese)
        _ = buffer.receive("甲乙", final: true, start: 0, end: 2, speaker: nil, now: 2,
                           timedSpans: [
                            .init(utf16Start: 0, utf16End: 1, start: 0, end: 1),
                            .init(utf16Start: 1, utf16End: 2, start: 1, end: 2)
                           ])
        _ = buffer.finish()

        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 0, end: 1, speakerSlot: 0),
            .init(speechProbability: 0.95, activeSpeakers: 1, start: 1, end: 2, speakerSlot: 2)
        ])
        _ = buffer.applySpeakerTimeline(timeline)
        let row = try! XCTUnwrap(buffer.rows.first)
        XCTAssertNil(row.speaker)
        XCTAssertEqual(row.speakerSpans.count, 2)
        XCTAssertEqual(Set(row.speakerSpans.compactMap(\.speaker)), Set([0, 2]))
        XCTAssertEqual(row.speakerSpans.map(\.utf16Start), [0, 1])
        var mapper = SoftSpeakerMapper()
        XCTAssertEqual(mapper.hint(for: row), .mixed)
    }

    func testSoftMapperCountsConfidentSpeechInsteadOfWholeCaptionDuration() {
        var mapper = SoftSpeakerMapper()
        var first = Caption(captureID: UUID(), language: .japanese, source: "A",
                            start: 0, end: 5, isFinal: true)
        first.speaker = 0
        first.speakerSpans = [
            .init(utf16Start: 0, utf16End: 1, start: 0, end: 5,
                  speaker: 0, confidentSpeech: 0.1, overlap: false)
        ]
        var second = Caption(captureID: first.captureID, language: .japanese, source: "B",
                             start: 5, end: 10, isFinal: true)
        second.speaker = 2
        second.speakerSpans = [
            .init(utf16Start: 0, utf16End: 1, start: 5, end: 10,
                  speaker: 2, confidentSpeech: 0.1, overlap: false)
        ]
        XCTAssertEqual(mapper.hint(for: first), .neutral)
        XCTAssertEqual(mapper.hint(for: second), .neutral)
        XCTAssertEqual(mapper.resolvedHint(slot: 0), .neutral)
        XCTAssertEqual(mapper.resolvedHint(slot: 2), .neutral)
    }

    func testSpeakerTimelineToleratesSilenceButRejectsConfidentOverlapOrConflict() {
        var timeline = SpeechTimeline()
        timeline.append([
            .init(speechProbability: 0.92, activeSpeakers: 1, start: 0, end: 0.4, speakerSlot: 4),
            .init(speechProbability: 0.08, activeSpeakers: 0, start: 0.4, end: 0.6),
            .init(speechProbability: 0.91, activeSpeakers: 1, start: 0.6, end: 1.0, speakerSlot: 4)
        ])
        XCTAssertEqual(timeline.speaker(start: 0, end: 1), 4)

        var overlap = SpeechTimeline()
        overlap.append([
            .init(speechProbability: 0.9, activeSpeakers: 1, start: 0, end: 0.4, speakerSlot: 4),
            .init(speechProbability: 0.9, activeSpeakers: 2, start: 0.4, end: 0.6),
            .init(speechProbability: 0.9, activeSpeakers: 1, start: 0.6, end: 1, speakerSlot: 4)
        ])
        XCTAssertNil(overlap.speaker(start: 0, end: 1))

        var conflict = SpeechTimeline()
        conflict.append([
            .init(speechProbability: 0.9, activeSpeakers: 1, start: 0, end: 0.5, speakerSlot: 4),
            .init(speechProbability: 0.9, activeSpeakers: 1, start: 0.5, end: 1, speakerSlot: 7)
        ])
        XCTAssertNil(conflict.speaker(start: 0, end: 1))
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
    func testSoftGutterLateSpeakerEvidenceIsNotConsumedByEarlierNeutralLookup() {
        var mapper = SoftSpeakerMapper()
        XCTAssertEqual(mapper.hint(slot: nil, start: 0, end: 1), .neutral)
        XCTAssertEqual(mapper.hint(slot: 0, start: 0, end: 1), .neutral)
        XCTAssertEqual(mapper.hint(slot: 0, start: 1, end: 2), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 2, end: 3), .neutral)
        XCTAssertEqual(mapper.hint(slot: 2, start: 3, end: 4), .second)
        XCTAssertEqual(mapper.resolvedHint(slot: 0), .first)
        XCTAssertEqual(mapper.resolvedHint(slot: 2), .second)
    }

    func testSoftGutterRepeatedAudioRangeDoesNotDoubleCountEvidence() {
        var mapper = SoftSpeakerMapper()
        _ = mapper.hint(slot: 0, start: 0, end: 1)
        _ = mapper.hint(slot: 0, start: 1, end: 2)
        // Two seconds of genuinely confident B speech are enough on their own; replaying
        // the identical range must not add more evidence or change the mapping.
        XCTAssertEqual(mapper.hint(slot: 2, start: 2, end: 4), .second)
        XCTAssertEqual(mapper.hint(slot: 2, start: 2, end: 4), .second)
        XCTAssertEqual(mapper.hint(slot: 0, start: 4, end: 5), .first)
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
    func testLateAnalysisBackfillsRecentPCMWithoutHoldingPrimary() async throws {
        let pipeline = AudioPreprocessor()
        let (raw, _) = try await pipeline.process(Self.pcm(count: 4800, time: 5, amplitude: 0.2))
        XCTAssertTrue(raw.allSatisfy { $0.decision == nil })
        await pipeline.installPrepared(analysis: PatternAnalysis(delay: 0.1), enhancement: nil)
        let (next, _) = try await pipeline.process(Self.pcm(count: 9600, time: 5.1, amplitude: 0.2))
        let outputs = raw + next + (try await pipeline.finish())
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.2, count: 14400))
        // Primary realtime output was already emitted and is never held/re-written by
        // delayed diarization, but the metadata path must recover the retained 5.0 s PCM.
        XCTAssertTrue(outputs.allSatisfy { $0.decision == nil })
        XCTAssertTrue(analysis.contains { $0.start <= 5.00001 && $0.speakerSlot == 0 })
        XCTAssertTrue(analysis.allSatisfy { $0.start >= 5.0-0.00001 })
    }

    func testLateAnalysisBackfillSurvivesSourceBoundary() async throws {
        let pipeline = AudioPreprocessor()
        let (first, _) = try await pipeline.process(Self.pcm(count: 4800, time: 0, amplitude: 0.2))
        let (second, _) = try await pipeline.process(Self.pcm(count: 4800, time: 2, amplitude: 0.2))
        XCTAssertFalse(first.isEmpty); XCTAssertFalse(second.isEmpty)
        await pipeline.installPrepared(analysis: PatternAnalysis(), enhancement: nil)
        let (third, _) = try await pipeline.process(Self.pcm(count: 4800, time: 2.1, amplitude: 0.2))
        _ = third + (try await pipeline.finish())
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertTrue(analysis.contains { $0.start <= 0.00001 }, "pre-boundary retained PCM must be backfilled")
        XCTAssertTrue(analysis.contains { $0.start >= 1.99999 }, "post-boundary segment must keep source time after reset")
    }

    func testR5KNormalAudioSourceBoundariesDoNotUseFailureBudget() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.installPrepared(analysis: PatternAnalysis(), enhancement: nil)
        var primaryFrames = 0
        // A normal audio clock discontinuity needs a fresh identity epoch, not
        // a counted model failure. More than two transitions must be supported.
        for i in 0..<6 {
            let (output, _) = try await pipeline.process(
                Self.pcm(count: 4800, time: Double(i) * 2, amplitude: 0.2))
            primaryFrames += output.reduce(0) { $0 + Int($1.buffer.frameLength) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let tail = try await pipeline.finish()
        primaryFrames += tail.reduce(0) { $0 + Int($1.buffer.frameLength) }
        let updates = await pipeline.takeAnalysisUpdates()
        XCTAssertEqual(primaryFrames, 6 * 4800, "Source boundaries cannot lose Primary PCM")
        XCTAssertTrue(updates.contains { $0.start >= 9.99 },
                      "Even the last of six segments must retain live diarization")
    }

    func testAnalysisFailureRecoversFromRecentPCMWithoutStoppingPrimary() async throws {
        let pipeline = AudioPreprocessor()
        await pipeline.installPrepared(analysis: RecoveringAnalysis(), enhancement: nil)
        let (first, _) = try await pipeline.process(Self.pcm(count: 4800, time: 0, amplitude: 0.2))
        try await Task.sleep(for: .milliseconds(50))
        let (second, metrics) = try await pipeline.process(Self.pcm(count: 4800, time: 0.1, amplitude: 0.2))
        let outputs = first + second + (try await pipeline.finish())
        let analysis = await pipeline.takeAnalysisUpdates()
        XCTAssertEqual(Self.samples(outputs), [Float](repeating: 0.2, count: 9600))
        XCTAssertTrue(metrics.warnings.contains { $0.contains("자동 복구") })
        XCTAssertTrue(analysis.contains { $0.start <= 0.00001 && $0.speakerSlot == 0 })
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
    func testSpeakerActivityStabilizerUsesTemporalHysteresis() {
        var gate = SpeakerActivityStabilizer(slotCount: 3)
        let onset = gate.classify([0.75, 0.1, 0.1])
        XCTAssertEqual(onset.activeSlots, [])
        XCTAssertEqual(onset.speechProbability, 0, accuracy: 0.0001)
        XCTAssertEqual(gate.classify([0.76, 0.1, 0.1]).activeSlots, [0])
        // One low frame must not erase a previously stable speaker.
        XCTAssertEqual(gate.classify([0.2, 0.1, 0.1]).activeSlots, [0])
        XCTAssertEqual(gate.classify([0.2, 0.1, 0.1]).activeSlots, [])
    }

    func testSpeakerActivityStabilizerPreservesThreeSpeakerOverflowEvidence() {
        var gate = SpeakerActivityStabilizer(slotCount: 4)
        _ = gate.classify([0.7, 0.75, 0.8, 0.1])
        let stable = gate.classify([0.7, 0.75, 0.8, 0.1])
        XCTAssertEqual(stable.activeSlots, [2, 1])
        XCTAssertEqual(stable.detectedSpeakerCount, 3)
        XCTAssertEqual(stable.speechProbability, 0.8, accuracy: 0.0001)
    }

    func testThreeSpeakerStabilizerEvidenceActuallyReachesOverlapGateAsThree() {
        var stabilizer = SpeakerActivityStabilizer(slotCount: 4)
        var overlap = OverlapGate()
        _ = stabilizer.classify([0.7, 0.75, 0.8, 0.1])
        let stable = stabilizer.classify([0.7, 0.75, 0.8, 0.1])
        XCTAssertEqual(stable.detectedSpeakerCount, 3)
        XCTAssertFalse(overlap.observe(activeSpeakers: stable.detectedSpeakerCount, probability: stable.speechProbability))
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

private actor RecoveringAnalysis: SpeechAnalysisProvider {
    private var failedOnce = false
    private var elapsed: Double = 0
    func process(_ mono: [Float], sampleRate: Double) throws -> [SpeechDecision] {
        if !failedOnce {
            failedOnce = true
            throw AppFailure.message("synthetic analysis failure")
        }
        let start = elapsed
        elapsed += Double(mono.count)/sampleRate
        guard elapsed > start else { return [] }
        return [.init(speechProbability: 1, activeSpeakers: 1, start: start, end: elapsed, speakerSlot: 0)]
    }
    func finish() -> [SpeechDecision] { [] }
    func reset() { elapsed = 0 }
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
