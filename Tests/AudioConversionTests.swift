import XCTest
import AVFoundation
import Speech
import CoreMedia
@testable import JPLive

// These exercise real AVAudioConverter / AnalyzerInput buffers on an Apple SDK.
// No Speech model, microphone, network, translation request or Worker is used.
final class AudioConversionTests: XCTestCase {
    func testSourceClockLongRunDoesNotAccumulateChunkRounding() throws {
        var clock = AudioSourceClock()
        for index in 0..<100_000 {
            let boundary = try clock.accept(time: 17 + Double(index * 441) / 44100, frames: 441, rate: 44100)
            XCTAssertEqual(boundary, index == 0)
        }
        XCTAssertEqual(try XCTUnwrap(clock.end), 1017, accuracy: 0.000000001)
    }
    func testSourceClockDetectsOneSampleGapAndRejectsOneSampleOverlap() throws {
        var clock = AudioSourceClock()
        _ = try clock.accept(time: 0, frames: 480, rate: 48000)
        XCTAssertTrue(try clock.accept(time: 481.0/48000, frames: 480, rate: 48000))
        XCTAssertThrowsError(try clock.accept(time: 960.0/48000, frames: 480, rate: 48000))
    }
    func testSourceClockRejectsInvalidInputWithoutAdvancing() throws {
        var clock = AudioSourceClock()
        _ = try clock.accept(time: 3, frames: 480, rate: 48000)
        for time in [Double.nan, .infinity, -1] {
            XCTAssertThrowsError(try clock.accept(time: time, frames: 480, rate: 48000))
        }
        XCTAssertThrowsError(try clock.accept(time: 3.01, frames: 480, rate: 0))
        XCTAssertThrowsError(try clock.accept(time: 3.01, frames: 0, rate: 48000))
        XCTAssertEqual(try XCTUnwrap(clock.end), 3.01, accuracy: 0.000000001)
    }
    func testStreamingResamplingPreservesDurationAcrossRatesAndIrregularChunks() throws {
        for rate in [8000.0, 16000, 22050, 32000, 44100, 48000, 96000] {
            let values = signal(count: Int(rate) + 37, rate: rate)
            let output = try resample(values, rate: rate, outputRate: 48000, sizes: [1, 47, 441, 4800, 17])
            let count = output.reduce(0) { $0 + Int($1.buffer.frameLength) }
            XCTAssertEqual(Double(count), Double(values.count)*48000/rate, accuracy: 1.1, "rate \(rate)")
            assertPCMContinuity(output, origin: 3)
            XCTAssertTrue(samples(output).allSatisfy(\.isFinite))
        }
    }
    func testResamplingContentIsIndependentOfSourceChunkBoundaries() throws {
        let values = signal(count: 44100 + 71, rate: 44100)
        let whole = samples(try resample(values, rate: 44100, outputRate: 48000, sizes: [values.count]))
        let pieces = samples(try resample(values, rate: 44100, outputRate: 48000, sizes: [1, 31, 997, 4410]))
        XCTAssertEqual(whole.count, pieces.count)
        let error = zip(whole, pieces).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(error, 0.0001)
    }
    func testResamplerPreservesImpulsePositionsIncludingTail() throws {
        var values = [Float](repeating: 0, count: 44100)
        let positions = [441, 22050, 44000]
        for index in positions { values[index] = 0.8 }
        let output = samples(try resample(values, rate: 44100, outputRate: 48000, sizes: [441, 7, 101]))
        for position in positions {
            let expected = Int((Double(position)*48000/44100).rounded())
            let range = max(0, expected-16)..<min(output.count, expected+17)
            XCTAssertGreaterThan(range.map { abs(output[$0]) }.max() ?? 0, 0.2)
        }
    }
    func testVeryShortEOFAndDoubleFlushDoNotDuplicateAudio() throws {
        let input = makeBuffer(signal(count: 37, rate: 44100), rate: 44100)
        let converter = try StreamingPCMConverter(from: input.format, to: format(48000), origin: 0)
        let first = try converter.convert(input)
        let tail = try converter.flush()
        XCTAssertEqual(Double((first + tail).reduce(0) { $0 + Int($1.buffer.frameLength) }), 37*48000.0/44100, accuracy: 1.1)
        XCTAssertTrue(try converter.flush().isEmpty)
        XCTAssertThrowsError(try converter.convert(input))
    }
    func testSpeechInputTenMillisecondFramesUseConvertedSampleClock() throws {
        for rate in [16000.0, 24000, 44100, 48000] {
            let converter = SpeechInputConverter(format: format(rate))
            var inputs: [AnalyzerInput] = []
            for index in 0..<1000 {
                inputs += try converter.convert(PCMChunk(buffer: makeBuffer(signal(count: 480, rate: 48000), rate: 48000),
                                                         time: 4 + Double(index)/100))
            }
            inputs += try converter.flush()
            let end = try assertAnalyzerContinuity(inputs, start: 4)
            XCTAssertEqual(end.seconds, 14, accuracy: 1.1/rate)
            XCTAssertTrue(try converter.flush().isEmpty)
        }
    }
    func testSpeechInputGapRemainsInAnalyzerTimeline() throws {
        let converter = SpeechInputConverter(format: format(16000))
        let buffer = makeBuffer(signal(count: 4800, rate: 48000), rate: 48000)
        var inputs = try converter.convert(PCMChunk(buffer: buffer, time: 2))
        inputs += try converter.convert(PCMChunk(buffer: makeBuffer(signal(count: 4800, rate: 48000), rate: 48000), time: 5))
        inputs += try converter.flush()
        var end = CMTime(seconds: 2, preferredTimescale: 48000)
        var gaps: [(Double, Double)] = []
        for input in inputs where input.buffer.frameLength > 0 {
            let start = input.bufferStartTime ?? end
            XCTAssertGreaterThanOrEqual(CMTimeCompare(start, end), 0)
            if start.seconds - end.seconds > 1 { gaps.append((end.seconds, start.seconds)) }
            end = CMTimeAdd(start, duration(input.buffer))
        }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(try XCTUnwrap(gaps.first).0, 2.1, accuracy: 1.1/16000)
        XCTAssertEqual(try XCTUnwrap(gaps.first).1, 5, accuracy: 1.0/48000)
    }
    func testFractionalSourceOriginDoesNotCreateNanosecondOverlaps() throws {
        let converter = SpeechInputConverter(format: format(44100))
        let origin = 9.123456789
        var inputs: [AnalyzerInput] = []
        for index in 0..<301 {
            inputs += try converter.convert(PCMChunk(buffer: makeBuffer(signal(count: 480, rate: 48000), rate: 48000),
                                                     time: origin + Double(index)/100))
        }
        inputs += try converter.flush()
        var end: CMTime?
        for input in inputs where input.buffer.frameLength > 0 {
            let start = input.bufferStartTime ?? end ?? .zero
            if let end { XCTAssertGreaterThanOrEqual(CMTimeCompare(start, end), 0) }
            else { XCTAssertEqual(start.seconds, origin, accuracy: 2.0/44100) }
            end = CMTimeAdd(start, duration(input.buffer))
        }
        XCTAssertEqual(try XCTUnwrap(end).seconds, origin + 3.01, accuracy: 2.0/44100)
    }
    @MainActor
    func testFileEOFAndRestartResetSourceTimebase() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = makeBuffer(signal(count: 517, rate: 48000), rate: 48000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
        }
        let source = FileAudioInput(url: url)
        for _ in 0..<2 {
            var chunks: [PCMChunk] = []
            let stream = try await source.start()
            for try await chunk in stream { chunks.append(chunk) }
            await source.stop()
            XCTAssertEqual(chunks.first?.time, 0)
            XCTAssertEqual(chunks.reduce(0) { $0 + Int($1.buffer.frameLength) }, 517)
        }
    }
    @MainActor
    func testFileStopAndRestartDoNotReusePreviousProducer() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = makeBuffer(signal(count: 48000, rate: 48000), rate: 48000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
        }
        let source = FileAudioInput(url: url)
        var first = try await source.start().makeAsyncIterator()
        let old = try await first.next()
        XCTAssertEqual(old?.time, 0)
        await source.stop()
        await source.stop()
        var next = try await source.start().makeAsyncIterator()
        let fresh = try await next.next()
        XCTAssertEqual(fresh?.time, 0)
        await source.stop()
    }
    func testSpeechInputRejectsBackwardTimeAndNewRunStartsAtZero() throws {
        let buffer = makeBuffer(signal(count: 480, rate: 48000), rate: 48000)
        let previous = SpeechInputConverter(format: format(16000))
        _ = try previous.convert(PCMChunk(buffer: buffer, time: 12))
        XCTAssertThrowsError(try previous.convert(PCMChunk(buffer: buffer, time: 0)))
        let next = SpeechInputConverter(format: format(16000))
        let result = try next.convert(PCMChunk(buffer: buffer, time: 0)) + next.flush()
        _ = try assertAnalyzerContinuity(result, start: 0)
    }
    func testPreprocessorFlushFeedsTailBeforeClosingAnalysis() async throws {
        let pipeline = AudioPreprocessor()
        let provider = CountingAnalysis()
        await pipeline.setProviders(analysis: provider, enhancement: nil)
        let input = makeBuffer(signal(count: 44137, rate: 44100), rate: 44100)
        let (head, _) = try await pipeline.process(PCMChunk(buffer: input, time: 8))
        let tail = try await pipeline.finish()
        let seen = await provider.totalFrames
        XCTAssertEqual(seen, (head + tail).reduce(0) { $0 + Int($1.buffer.frameLength) })
        XCTAssertEqual(Double(seen), 44137*48000.0/44100, accuracy: 1.1)
        assertPCMContinuity(head + tail, origin: 8)
    }
    func testPreprocessorTracksConvertedPCMThroughBothConversionStages() async throws {
        let pipeline = AudioPreprocessor()
        let speech = SpeechInputConverter(format: format(16000))
        var inputs: [AnalyzerInput] = []
        for index in 0..<101 {
            let count = index == 100 ? 37 : 441
            let buffer = makeBuffer(signal(count: count, rate: 44100), rate: 44100)
            let (chunks, _) = try await pipeline.process(PCMChunk(buffer: buffer, time: Double(index)/100))
            for chunk in chunks { inputs += try speech.convert(chunk) }
        }
        let tails = try await pipeline.finish()
        for tail in tails { inputs += try speech.convert(tail) }
        inputs += try speech.flush()
        let end = try assertAnalyzerContinuity(inputs, start: 0)
        XCTAssertEqual(end.seconds, 1 + 37.0/44100, accuracy: 2.0/16000)
    }
    func testPreprocessorFlushIsIdempotentAndClosedPipelineRejectsAppend() async throws {
        let pipeline = AudioPreprocessor()
        let chunk = PCMChunk(buffer: makeBuffer(signal(count: 480, rate: 48000), rate: 48000), time: 0)
        _ = try await pipeline.process(chunk)
        _ = try await pipeline.finish()
        let again = try await pipeline.finish()
        XCTAssertTrue(again.isEmpty)
        do { _ = try await pipeline.process(chunk); XCTFail("Closed pipeline accepted audio") }
        catch { }
    }
    func testFormatChangeFlushesOldFormatBeforeNewSegment() async throws {
        let pipeline = AudioPreprocessor()
        let (first, _) = try await pipeline.process(PCMChunk(buffer: makeBuffer(signal(count: 4410, rate: 44100), rate: 44100), time: 0))
        let (second, _) = try await pipeline.process(PCMChunk(buffer: makeBuffer(signal(count: 3200, rate: 32000), rate: 32000), time: 1))
        let all = first + second + (try await pipeline.finish())
        XCTAssertEqual(Double(all.reduce(0) { $0 + Int($1.buffer.frameLength) }), 9600, accuracy: 2)
        XCTAssertTrue(all.contains { abs($0.time - 1) < 0.000000001 })
    }

    private func format(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }
    private func makeBuffer(_ values: [Float], rate: Double) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(pcmFormat: format(rate), frameCapacity: AVAudioFrameCount(values.count))!
        result.frameLength = AVAudioFrameCount(values.count)
        for index in values.indices { result.floatChannelData![0][index] = values[index] }
        return result
    }
    private func signal(count: Int, rate: Double) -> [Float] {
        (0..<count).map { Float(sin(Double($0)*2*Double.pi*440/rate))*0.1 }
    }
    private func samples(_ chunks: [PCMChunk]) -> [Float] {
        chunks.flatMap { Array(UnsafeBufferPointer(start: $0.buffer.floatChannelData![0], count: Int($0.buffer.frameLength))) }
    }
    private func resample(_ values: [Float], rate: Double, outputRate: Double, sizes: [Int]) throws -> [PCMChunk] {
        let converter = try StreamingPCMConverter(from: format(rate), to: format(outputRate), origin: 3)
        var cursor = 0; var index = 0; var output: [PCMChunk] = []
        while cursor < values.count {
            let count = min(sizes[index % sizes.count], values.count-cursor)
            output += try converter.convert(makeBuffer(Array(values[cursor..<cursor+count]), rate: rate))
            cursor += count; index += 1
        }
        return output + (try converter.flush())
    }
    private func assertPCMContinuity(_ chunks: [PCMChunk], origin: Double, file: StaticString = #filePath, line: UInt = #line) {
        var frames = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.time, origin + Double(frames)/chunk.buffer.format.sampleRate, accuracy: 0.000000001, file: file, line: line)
            frames += Int(chunk.buffer.frameLength)
        }
    }
    private func duration(_ buffer: AVAudioPCMBuffer) -> CMTime {
        CMTime(value: Int64(buffer.frameLength), timescale: CMTimeScale(buffer.format.sampleRate))
    }
    private func assertAnalyzerContinuity(_ inputs: [AnalyzerInput], start: Double,
                                          file: StaticString = #filePath, line: UInt = #line) throws -> CMTime {
        XCTAssertFalse(inputs.isEmpty, file: file, line: line)
        var end = CMTime(seconds: start, preferredTimescale: 48000)
        for input in inputs where input.buffer.frameLength > 0 {
            let time = input.bufferStartTime ?? end
            XCTAssertEqual(CMTimeCompare(time, end), 0, file: file, line: line)
            end = CMTimeAdd(time, duration(input.buffer))
        }
        return end
    }
}

private actor CountingAnalysis: SpeechAnalysisProvider {
    private(set) var totalFrames = 0
    func process(_ mono: [Float], sampleRate: Double) async throws -> [SpeechDecision] {
        totalFrames += mono.count
        return []
    }
    func finish() async throws -> [SpeechDecision] { [] }
    func reset() async { totalFrames = 0 }
}
