import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import CoreMedia

// Source continuity is measured on the source sample grid, against the cumulative
// frame count. Rounding resolves sub-sample representation noise; it never clamps
// a timestamp to the previous end. A missing/duplicated whole sample is a boundary/error.
struct AudioSourceClock {
    private(set) var origin: Double?
    private(set) var sampleRate: Double = 0
    private(set) var frames: Int64 = 0
    var end: Double? { origin.map { $0 + Double(frames) / sampleRate } }

    mutating func accept(time: Double, frames count: AVAudioFrameCount, rate: Double) throws -> Bool {
        guard time.isFinite, time >= 0, rate.isFinite, rate >= 1, rate <= 384000,
              rate.rounded() == rate, count > 0 else {
            throw AppFailure.message("오디오 시각·샘플 수·샘플레이트 오류")
        }
        var boundary = origin == nil
        if let end {
            let delta = (time - end) * min(rate, sampleRate)
            guard delta.isFinite, delta.rounded() >= 0 else {
                throw AppFailure.message("원본 오디오 시각이 겹치거나 역행했습니다.")
            }
            boundary = delta.rounded() > 0 || rate != sampleRate
        }
        if boundary { origin = time; sampleRate = rate; frames = 0 }
        let (next, overflow) = frames.addingReportingOverflow(Int64(count))
        guard !overflow else { throw AppFailure.message("오디오 샘플 수 범위 초과") }
        frames = next
        return boundary
    }
}

// One format and one continuous source segment per instance. Input buffers are
// supplied once, in requested-size slices. .noDataNow is temporary; only flush()
// sends .endOfStream. Every returned output buffer is retained by its consumer.
final class StreamingPCMConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    let origin: Double
    private let converter: AVAudioConverter?
    private var outputFrames: Int64 = 0
    private var diagnosticInputFrames: Int64 = 0
    private let diagnosticLabel: String?
    private var closed = false

    init(from input: AVAudioFormat, to output: AVAudioFormat, origin: Double, diagnosticLabel: String? = nil) throws {
        self.diagnosticLabel = diagnosticLabel
        inputFormat = input; outputFormat = output; self.origin = origin
        guard input.sampleRate > 0, output.sampleRate > 0, origin.isFinite else {
            throw AppFailure.message("오디오 변환 형식 오류")
        }
        if input == output { converter = nil }
        else {
            guard let value = AVAudioConverter(from: input, to: output) else {
                throw AppFailure.message("오디오 형식 변환기 생성 실패")
            }
            // Match Apple's iOS 26 sample: no external priming frames. This
            // sacrifices boundary filter quality; internal held samples still
            // require draining. Output time comes from emitted samples, not input chunks.
            value.primeMethod = .none
            converter = value
        }
        trace("init")
    }
    func convert(_ input: AVAudioPCMBuffer) throws -> [PCMChunk] {
        guard !closed, input.format == inputFormat else {
            throw AppFailure.message("종료되었거나 입력 형식이 바뀐 변환기를 사용할 수 없습니다.")
        }
        guard input.frameLength > 0 else { return [] }
        if diagnosticLabel != nil { diagnosticInputFrames += Int64(input.frameLength) }
        if converter == nil { return [stamp(input)] }
        return try drain(input)
    }
    func flush() throws -> [PCMChunk] {
        guard !closed else { return [] }
        closed = true
        let before = outputFrames
        trace("flush.before", outputBeforeFlush: before)
        let result = converter == nil ? [] : try drain(nil)
        trace("flush.after", outputBeforeFlush: before)
        return result
    }
    // Observation only: no converter configuration, audio, timing, or test threshold changes.
    private func trace(_ event: String, outputBeforeFlush: Int64? = nil) {
        guard let diagnosticLabel, let converter else { return }
        let before = outputBeforeFlush ?? outputFrames
        print("[PCM_TRACE] case=\(diagnosticLabel) event=\(event) inputRate=\(inputFormat.sampleRate) outputRate=\(outputFormat.sampleRate) primeMethod=\(converter.primeMethod) primeMethodRaw=\(converter.primeMethod.rawValue) leadingFrames=\(converter.primeInfo.leadingFrames) trailingFrames=\(converter.primeInfo.trailingFrames) inputFrames=\(diagnosticInputFrames) outputBeforeFlush=\(before) flushFrames=\(outputFrames - before) outputTotal=\(outputFrames)")
    }
    private func stamp(_ buffer: AVAudioPCMBuffer) -> PCMChunk {
        let time = origin + Double(outputFrames) / outputFormat.sampleRate
        outputFrames += Int64(buffer.frameLength)
        return PCMChunk(buffer: buffer, time: time)
    }
    private func drain(_ input: AVAudioPCMBuffer?) throws -> [PCMChunk] {
        guard let converter else { return [] }
        var cursor: AVAudioFrameCount = 0
        var outputs: [PCMChunk] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
                throw AppFailure.message("오디오 메모리 할당 실패")
            }
            var conversionError: NSError?
            var supplyError: Error?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                guard let input else { state.pointee = .endOfStream; return nil }
                guard cursor < input.frameLength else { state.pointee = .noDataNow; return nil }
                let count = min(requested, input.frameLength - cursor)
                guard count > 0 else { state.pointee = .noDataNow; return nil }
                do {
                    let slice = try Self.copy(input, from: cursor, count: count)
                    cursor += count; state.pointee = .haveData
                    return slice
                } catch { supplyError = error; state.pointee = .noDataNow; return nil }
            }
            if let supplyError { throw supplyError }
            if status == .error { throw conversionError ?? NSError(domain: "PCMConversion", code: 1) }
            if output.frameLength > 0 { outputs.append(stamp(output)) }
            switch status {
            case .haveData:
                guard output.frameLength > 0 else { throw AppFailure.message("오디오 변환기가 진행하지 못했습니다.") }
            case .inputRanDry:
                guard let input, cursor == input.frameLength else {
                    throw AppFailure.message("오디오 변환기의 EOF/입력 소비 상태 오류")
                }
                return outputs
            case .endOfStream:
                guard input == nil else { throw AppFailure.message("오디오 변환기가 입력 중 종료됐습니다.") }
                return outputs
            case .error: throw AppFailure.message("오디오 변환 실패")
            @unknown default: throw AppFailure.message("알 수 없는 오디오 변환 상태")
            }
        }
    }
    private static func copy(_ input: AVAudioPCMBuffer, from start: AVAudioFrameCount,
                             count: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else {
            throw AppFailure.message("오디오 입력 복사 실패")
        }
        output.frameLength = count
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        let stride = Int(input.format.streamDescription.pointee.mBytesPerFrame)
        guard stride > 0, source.count == destination.count else {
            throw AppFailure.message("PCM 채널 배치 오류")
        }
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData,
                  Int(source[index].mDataByteSize) >= (Int(start) + Int(count)) * stride else {
                throw AppFailure.message("PCM 입력 길이 오류")
            }
            dst.copyMemory(from: src.advanced(by: Int(start) * stride), byteCount: Int(count) * stride)
        }
        return output
    }
}

// Shared STT adapter: iOS 26 uses the streaming converter and a converted-sample
// clock; only the iOS 27 target references Apple's newly introduced converter.
final class SpeechInputConverter {
    private let format: AVAudioFormat
    private let diagnosticLabel: String?
    private var sourceClock = AudioSourceClock()
    private var sourceFormat: AVAudioFormat?
    private var closed = false
    private var analyzerEnd: CMTime?
    #if PHASE2
    private var native: AnalyzerInputConverter?
    #else
    private var pcm: StreamingPCMConverter?
    private var segmentOrigin = CMTime.zero
    private var segmentFrames: Int64 = 0
    #endif

    init(format: AVAudioFormat, diagnosticLabel: String? = nil) {
        self.format = format; self.diagnosticLabel = diagnosticLabel
    }
    func convert(_ chunk: PCMChunk) throws -> [AnalyzerInput] {
        guard !closed else { throw AppFailure.message("종료된 STT 변환기에 입력했습니다.") }
        guard chunk.buffer.frameLength > 0 else { return [] }
        let boundary = try sourceClock.accept(time: chunk.time, frames: chunk.buffer.frameLength,
                                              rate: chunk.buffer.format.sampleRate)
        let newSegment = boundary || sourceFormat != chunk.buffer.format
        var result: [AnalyzerInput] = []
        if newSegment {
            result += try flushSegment()
            sourceFormat = chunk.buffer.format
            #if PHASE2
            native = AnalyzerInputConverter(analyzerFormat: format, configurationHandler: nil)
            #else
            pcm = try StreamingPCMConverter(from: chunk.buffer.format, to: format, origin: chunk.time, diagnosticLabel: diagnosticLabel)
            guard format.sampleRate >= 1, format.sampleRate <= 384000,
                  format.sampleRate.rounded() == format.sampleRate else {
                throw AppFailure.message("STT 출력 샘플레이트 오류")
            }
            // One conversion to the destination sample grid per segment. Mixing
            // a nanosecond origin with sample times can round consecutive CMTime
            // additions differently and recreate an overlap of one nanosecond.
            segmentOrigin = CMTime(seconds: chunk.time, preferredTimescale: CMTimeScale(format.sampleRate))
            segmentFrames = 0
            #endif
        }
        #if PHASE2
        // The source is 48 kHz PCM. Explicit time codes are needed only at a
        // source boundary. Never reuse a source time for manually converted PCM.
        let time = newSegment ? AVAudioTime(sampleTime: AVAudioFramePosition((chunk.time * 48000).rounded()), atRate: 48000) : nil
        result += try native?.convert(chunk.buffer, at: time) ?? []
        #else
        result += try (pcm?.convert(chunk.buffer) ?? []).map { try input($0.buffer) }
        #endif
        try validate(result)
        return result
    }
    func flush() throws -> [AnalyzerInput] {
        guard !closed else { return [] }
        closed = true
        let result = try flushSegment()
        try validate(result)
        return result
    }
    private func flushSegment() throws -> [AnalyzerInput] {
        #if PHASE2
        return try native?.flush() ?? []
        #else
        return try (pcm?.flush() ?? []).map { try input($0.buffer) }
        #endif
    }
    #if !PHASE2
    private func input(_ buffer: AVAudioPCMBuffer) throws -> AnalyzerInput {
        guard format.sampleRate.rounded() == format.sampleRate, format.sampleRate <= Double(Int32.max) else {
            throw AppFailure.message("STT 출력 샘플레이트 오류")
        }
        // Integer sample count: no repeated floating-point addition and no epsilon.
        let start = CMTimeAdd(segmentOrigin, CMTime(value: segmentFrames, timescale: CMTimeScale(format.sampleRate)))
        segmentFrames += Int64(buffer.frameLength)
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }
    #endif
    private func validate(_ inputs: [AnalyzerInput]) throws {
        for input in inputs where input.buffer.frameLength > 0 {
            let start = input.bufferStartTime ?? analyzerEnd ?? .zero
            guard start.isValid, start.isNumeric, start.seconds >= 0,
                  analyzerEnd.map({ CMTimeCompare(start, $0) >= 0 }) ?? true else {
                throw AppFailure.message("변환된 STT 오디오 시각이 겹쳤습니다. 변환 상태를 확인해야 합니다.")
            }
            let rate = input.buffer.format.sampleRate
            guard rate >= 1, rate <= 384000, rate.rounded() == rate else {
                throw AppFailure.message("STT 변환 출력 형식 오류")
            }
            analyzerEnd = CMTimeAdd(start, CMTime(value: Int64(input.buffer.frameLength), timescale: CMTimeScale(rate)))
        }
    }
}
