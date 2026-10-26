import Foundation
import CoreML
import AVFoundation

struct SeparatedAudio: Sendable {
    var start: Double
    var sampleRate: Double
    var stems: [[Float]]
}

struct StemSpeechFrame: Sendable {
    var start: Double
    var end: Double
    var probability: Float
}

struct SeparatedSpeechResult {
    var rows: [Caption]
    var speechFrames: [[StemSpeechFrame]]
}

struct SeparationTarget: Sendable, Hashable {
    var episode: OverlapEpisode
    var inferenceStart: Double
    var inferenceEnd: Double
    var isValid: Bool { episode.isValid && inferenceStart.isFinite && inferenceEnd.isFinite &&
        inferenceStart <= episode.start && inferenceEnd >= episode.end && inferenceEnd > inferenceStart }
}

// Probabilities refer to fixed-size blocks of the SAME stem, not the mixed audio.
// A missing detector is an explicit preparation failure, never fabricated speech.
protocol StemSpeechDetector: Actor {
    func probabilities(_ samples: [Float]) async throws -> [Float]
}

struct StemLeveling {
    static let detectionFrames = 4096 // pinned FluidAudio Silero contract: 16 kHz
    static func process(_ samples: [Float], probabilities: [Float]) throws -> [Float] {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }),
              probabilities.count == (samples.count + detectionFrames - 1) / detectionFrames,
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AppFailure.message("분리 음성과 음성 판별 구간이 일치하지 않습니다.")
        }
        // Each stem has its own envelope. Retain it across short frames within
        // this stem, but reset immediately in non-speech blocks to avoid boosting
        // residual music/noise with the preceding speech gain.
        var leveler = SpeechLeveler()
        var output: [Float] = []; output.reserveCapacity(samples.count)
        for (block, probability) in probabilities.enumerated() {
            let end = min(samples.count, (block + 1) * detectionFrames)
            var cursor = block * detectionFrames
            while cursor < end {
                let next = min(end, cursor + 160)
                output += leveler.process(Array(samples[cursor..<next]), speechProbability: probability,
                    allowUpwardGain: probability >= 0.65)
                cursor = next
            }
        }
        return output
    }
}

// Explicit model contract produced by Tools/export_separator.py. No weights are fabricated.
actor TwoSpeakerSeparator {
    private var model: MLModel?
    private let rate: Double = 16000
    private let window = 64000
    func prepare(modelURL: URL) throws {
        model = nil
        try Task.checkCancellation()
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        guard model.modelDescription.inputDescriptionsByName["mixture"]?.multiArrayConstraint?.shape == [1, 64000],
              model.modelDescription.outputDescriptionsByName["stems"]?.multiArrayConstraint?.shape == [1, 64000, 2] else {
            throw AppFailure.message("2화자 분리 모델 형식이 일치하지 않습니다.")
        }
        try Task.checkCancellation()
        self.model = model
    }
    func separate(_ samples: [Float], start: Double) throws -> SeparatedAudio {
        try Task.checkCancellation()
        guard let model, samples.count == window, start.isFinite, start >= 0,
              samples.allSatisfy({ $0.isFinite }) else {
            throw AppFailure.message("유효한 16kHz 4초 분리 입력과 준비된 모델이 필요합니다.")
        }
        let input = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
        for i in samples.indices { input[i] = NSNumber(value: samples[i]) }
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mixture": MLFeatureValue(multiArray: input)]))
        // Core ML's synchronous prediction cannot be interrupted halfway through;
        // cancellation still prevents its late output entering STT or the UI.
        try Task.checkCancellation()
        guard let output = prediction.featureValue(for: "stems")?.multiArrayValue,
              output.shape == [1, 64000, 2] else { throw AppFailure.message("분리 결과 형식 오류") }
        var stems = [[Float](repeating: 0, count: window), [Float](repeating: 0, count: window)]
        for t in 0..<window {
            for speaker in 0..<2 {
                let value = output[[0, NSNumber(value: t), NSNumber(value: speaker)]].floatValue
                guard value.isFinite else { throw AppFailure.message("분리 모델이 유효하지 않은 값을 반환했습니다.") }
                stems[speaker][t] = value
            }
        }
        return SeparatedAudio(start: start, sampleRate: rate, stems: stems)
    }
}

// Gating is tested separately from the model. Three-plus active speakers never enter a separator.
struct OverlapGate {
    private(set) var consecutive = 0
    mutating func observe(activeSpeakers: Int?, probability: Float?) -> Bool {
        guard activeSpeakers == 2, let probability, probability.isFinite,
              (0.65...1).contains(probability) else { consecutive = 0; return false }
        consecutive = min(3, consecutive + 1)
        return consecutive >= 3
    }
}

// Four-second model windows overlap by two seconds. Identify the lane permutation
// from their common waveform; ambiguity preserves the original mixed transcript.
struct SeparationStitcher {
    static let window = 64000
    static let hop = 32000
    private(set) var stems: [[Float]] = [[], []]
    private var previous: [[Float]]?
    mutating func append(_ candidate: [[Float]]) throws {
        guard candidate.count == 2, candidate.allSatisfy({
            $0.count == Self.window && $0.allSatisfy { $0.isFinite }
        }) else { throw AppFailure.message("분리 window 형식 오류") }
        var ordered = candidate
        if let previous {
            func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Double {
                var aa = 0.0, bb = 0.0, ab = 0.0
                for (x, y) in zip(a, b) { aa += Double(x*x); bb += Double(y*y); ab += Double(x*y) }
                guard aa > 0.000001, bb > 0.000001 else { return 0 }
                return ab / sqrt(aa*bb)
            }
            let a = correlation(previous[0].suffix(Self.hop), candidate[0].prefix(Self.hop))
            let b = correlation(previous[1].suffix(Self.hop), candidate[1].prefix(Self.hop))
            let c = correlation(previous[0].suffix(Self.hop), candidate[1].prefix(Self.hop))
            let d = correlation(previous[1].suffix(Self.hop), candidate[0].prefix(Self.hop))
            let same = a+b, swapped = c+d
            guard max(same, swapped) >= 1.0, abs(same-swapped) >= 0.25 else {
                throw AppFailure.message("분리 window의 화자 연결이 불확실하여 원본 자막을 유지합니다.")
            }
            if swapped > same { ordered.swapAt(0, 1) }
            let offset = stems[0].count - Self.hop
            for lane in 0..<2 {
                for i in 0..<Self.hop {
                    let weight = Float(i) / Float(Self.hop)
                    stems[lane][offset+i] = stems[lane][offset+i]*(1-weight) + ordered[lane][i]*weight
                }
                stems[lane] += ordered[lane].suffix(Self.hop)
            }
        } else { stems = ordered }
        previous = ordered
    }
}

// Retains immutable primary PCM references only. The heavy extraction/resampling
// belongs to the optional worker actor, never the required capture loop.
struct SeparationAudioWindow {
    private var chunks: [PCMChunk?] = []
    private var head = 0
    var count: Int { chunks.count-head }
    mutating func append(_ chunk: PCMChunk) {
        guard chunk.buffer.format.sampleRate == 48000, chunk.buffer.format.channelCount == 1,
              chunk.buffer.frameLength > 0, chunk.time.isFinite else { return }
        chunks.append(chunk)
        let end = chunk.time + Double(chunk.buffer.frameLength)/48000
        // Release expired buffers without rescanning/shifting 32 seconds of PCM
        // on EVERY fast-path append. Compact infrequently, amortized O(1).
        while head < chunks.count, let first = chunks[head],
              first.time + Double(first.buffer.frameLength)/48000 < end-32 || count > 4096 {
            chunks[head] = nil; head += 1
        }
        if head >= 128 { chunks.removeFirst(head); head = 0 }
    }
    func covering(start: Double, end: Double) -> [PCMChunk]? {
        guard start.isFinite, end.isFinite, end > start, end-start <= 20 else { return nil }
        var cursor = start
        var selected: [PCMChunk] = []
        for index in head..<chunks.count {
            guard let chunk = chunks[index] else { continue }
            let chunkEnd = chunk.time + Double(chunk.buffer.frameLength)/48000
            if chunkEnd <= start { continue }
            if chunk.time >= end { break }
            guard chunk.time <= cursor + 1.0/48000 else { return nil }
            selected.append(chunk); cursor = chunkEnd
            if cursor >= end - 1.0/48000 { return selected }
        }
        return nil
    }
}

actor SeparationProcessor {
    private let separator = TwoSpeakerSeparator()
    private var detector: (any StemSpeechDetector)?
    func prepare(_ url: URL) async throws {
        try await separator.prepare(modelURL: url)
        #if PHASE2 && canImport(FluidAudio)
        detector = try FluidStemSpeechDetector()
        #else
        throw AppFailure.message("분리 음성 판별 모델은 Phase 2에서 준비합니다.")
        #endif
    }
    func speechDetector() throws -> any StemSpeechDetector {
        guard let detector else { throw AppFailure.message("분리 음성 판별 모델 준비 전") }
        return detector
    }
    func process(_ chunks: [PCMChunk], start: Double, end: Double) async throws -> SeparatedAudio {
        try Task.checkCancellation()
        guard start.isFinite, end.isFinite, end > start, end-start <= 20,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw AppFailure.message("분리 오디오 범위 오류")
        }
        let converter = try StreamingPCMConverter(from: format, to: target, origin: start)
        var mono: [Float] = []
        var cursor = start
        for chunk in chunks {
            try Task.checkCancellation()
            guard chunk.buffer.format == format, let samples = chunk.buffer.floatChannelData?[0],
                  chunk.time <= cursor+1.0/48000 else { throw AppFailure.message("분리 입력 gap 또는 형식 오류") }
            let lower = max(0, Int(((start-chunk.time)*48000).rounded()))
            let upper = min(Int(chunk.buffer.frameLength), Int(((end-chunk.time)*48000).rounded()))
            guard upper > lower else { continue }
            let count = upper-lower
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw AppFailure.message("분리 오디오 버퍼 생성 실패")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = samples[lower+i] }
            for output in try converter.convert(buffer) {
                mono += Array(UnsafeBufferPointer(start: output.buffer.floatChannelData![0], count: Int(output.buffer.frameLength)))
            }
            cursor = chunk.time + Double(upper)/48000
        }
        guard cursor >= end-1.0/48000 else { throw AppFailure.message("분리 입력의 끝부분이 없습니다.") }
        for output in try converter.flush() {
            mono += Array(UnsafeBufferPointer(start: output.buffer.floatChannelData![0], count: Int(output.buffer.frameLength)))
        }
        guard !mono.isEmpty else { throw AppFailure.message("분리 입력이 비어 있습니다.") }
        var stitcher = SeparationStitcher()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let available = min(SeparationStitcher.window, mono.count-offset)
            var window = Array(mono[offset..<offset+available])
            window += Array(repeating: 0, count: SeparationStitcher.window-available)
            let result = try await separator.separate(window, start: start+Double(offset)/16000)
            try stitcher.append(result.stems)
            if offset + SeparationStitcher.window >= mono.count { break }
            offset += SeparationStitcher.hop
        }
        return SeparatedAudio(start: start, sampleRate: 16000,
            stems: stitcher.stems.map { Array($0.prefix(mono.count)) })
    }
}

@MainActor
final class SeparatedSpeechExperiment {
    // Shared recognition path for offline validation and bounded live revisions.
    func transcribe(_ audio: SeparatedAudio, language: SourceLanguage,
                    detector: any StemSpeechDetector) async throws -> SeparatedSpeechResult {
        guard audio.stems.count == 2, audio.sampleRate == 16000, audio.start.isFinite,
              audio.start >= 0, !audio.stems[0].isEmpty,
              audio.stems[0].count == audio.stems[1].count,
              audio.stems.allSatisfy({ $0.allSatisfy { $0.isFinite } }) else {
            throw AppFailure.message("같은 길이의 16kHz 두 stem과 유효한 시작 시각이 필요합니다.")
        }
        // Complete VAD/leveling before opening either recognizer. If either stem
        // fails, no partial pair is delivered or silently substituted.
        // Reject almost-identical stems before spending two recognizer passes on likely
        // crosstalk/duplication. Real simultaneous speakers need independently useful stems.
        func normalizedCorrelation(_ a: [Float], _ b: [Float]) -> Double {
            var aa = 0.0, bb = 0.0, ab = 0.0
            for (x, y) in zip(a, b) { aa += Double(x*x); bb += Double(y*y); ab += Double(x*y) }
            guard aa > 1e-7, bb > 1e-7 else { return 0 }
            return ab / sqrt(aa*bb)
        }
        guard abs(normalizedCorrelation(audio.stems[0], audio.stems[1])) < 0.92 else {
            throw AppFailure.message("두 분리 stem이 지나치게 유사하여 원본 자막을 유지합니다.")
        }

        var leveled: [[Float]] = []
        var speechFrames: [[StemSpeechFrame]] = []
        for stem in audio.stems {
            try Task.checkCancellation()
            let probabilities = try await detector.probabilities(stem)
            try Task.checkCancellation()
            leveled.append(try StemLeveling.process(stem, probabilities: probabilities))
            var frames: [StemSpeechFrame] = []
            for (block, probability) in probabilities.enumerated() {
                let lo = block * StemLeveling.detectionFrames
                let hi = min(stem.count, (block + 1) * StemLeveling.detectionFrames)
                guard hi > lo else { continue }
                frames.append(.init(start: audio.start + Double(lo)/audio.sampleRate,
                                    end: audio.start + Double(hi)/audio.sampleRate,
                                    probability: probability))
            }
            speechFrames.append(frames)
        }
        let captureID = UUID()
        var rows: [Caption] = []
        var failures: [String] = []
        // Recognize stems sequentially: never add TWO simultaneous analyzers on
        // after Primary STT. No partial results escape this method.
        for speaker in 0..<2 {
            let engine = AppleSpeechEngine()
            var transcript = TranscriptBuffer()
            transcript.begin(captureID: captureID, language: language)
            do {
                try Task.checkCancellation()
                try await engine.prepare(language: language, result: { text, final, start, end, finalizedThrough, timedSpans in
                    let shiftedSpans = timedSpans.map {
                        TimedTextSpan(utf16Start: $0.utf16Start, utf16End: $0.utf16End,
                                      start: audio.start+$0.start, end: audio.start+$0.end)
                    }
                    _ = transcript.receive(text, final: final, start: audio.start+start,
                        end: audio.start+end, speaker: speaker, now: ProcessInfo.processInfo.systemUptime,
                        finalizedThrough: finalizedThrough.map { audio.start + $0 },
                        timedSpans: shiftedSpans)
                }, failure: { failures.append($0) })
                let samples = leveled[speaker]
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false)!
                // Feed short buffers to avoid assuming an unbounded recognizer input size.
                var cursor = 0
                while cursor < samples.count {
                    try Task.checkCancellation()
                    let n = min(Int(audio.sampleRate/10), samples.count-cursor)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                    buffer.frameLength = AVAudioFrameCount(n)
                    for i in 0..<n { buffer.floatChannelData![0][i] = samples[cursor+i] }
                    try engine.append(PCMChunk(buffer: buffer, time: Double(cursor)/audio.sampleRate))
                    cursor += n
                    await Task.yield()
                }
                try await engine.finish()
                try Task.checkCancellation()
                if !failures.isEmpty { throw AppFailure.message(failures.joined(separator: " · ")) }
                _ = transcript.finish()
                let completed = transcript.rows.filter { $0.isFinal }
                guard !completed.isEmpty,
                      !transcript.rows.contains(where: { !$0.isFinal && SentenceBoundary.hasSemanticContent($0.source) }) else {
                    throw AppFailure.message("분리된 한 화자의 인식이 미완료되어 원본을 유지합니다.")
                }
                rows += completed.map { row in
                    var row = row
                    row.separationLane = speaker
                    // `speaker` from this private TranscriptBuffer is only the local
                    // separator lane. Never expose it as a global person identity.
                    row.speaker = nil
                    row.gutterHint = .neutral
                    row.speakerSpans = []
                    return row
                }
            } catch {
                let originalError = error
                do { try await engine.finish(aborting: true) }
                catch { throw AppFailure.message(originalError.localizedDescription + " · " + error.localizedDescription) }
                throw originalError
            }
        }
        let firstText = rows.filter { $0.separationLane == 0 }.map(\.source).joined()
        let secondText = rows.filter { $0.separationLane == 1 }.map(\.source).joined()
        guard firstText != secondText else { throw AppFailure.message("두 분리 결과가 같아 원본 자막을 유지합니다.") }
        return SeparatedSpeechResult(rows: rows.sorted { $0.start < $1.start }, speechFrames: speechFrames)
    }
}

struct SeparationAcceptance {
    static func validateStemIndependence(_ audio: SeparatedAudio, in episode: OverlapEpisode) throws {
        guard audio.stems.count == 2, audio.sampleRate > 0, episode.isValid else {
            throw AppFailure.message("분리 stem 검증 범위 오류")
        }
        let lo = max(0, Int(((episode.start-audio.start)*audio.sampleRate).rounded(.down)))
        let hi = min(audio.stems[0].count, Int(((episode.end-audio.start)*audio.sampleRate).rounded(.up)))
        guard hi > lo, audio.stems[1].count >= hi else {
            throw AppFailure.message("overlap stem 구간이 없습니다.")
        }
        var aa = 0.0, bb = 0.0, ab = 0.0
        for i in lo..<hi {
            let a = Double(audio.stems[0][i]), b = Double(audio.stems[1][i])
            aa += a*a; bb += b*b; ab += a*b
        }
        guard aa > 1e-7, bb > 1e-7 else {
            throw AppFailure.message("overlap에서 두 stem의 유효 음성 에너지를 확인하지 못했습니다.")
        }
        let correlation = abs(ab / sqrt(aa*bb))
        guard correlation < 0.90 else {
            throw AppFailure.message("overlap stem이 지나치게 유사하여 crosstalk 가능성 때문에 원본을 유지합니다.")
        }
    }

    static func normalized(_ text: String) -> [Character] {
        Array(text.lowercased().filter { ch in
            !ch.isWhitespace && ch.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        })
    }
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalized(a), y = normalized(b)
        guard !x.isEmpty, !y.isEmpty else { return 1 }
        var previous = Array(0...y.count)
        for (i, cx) in x.enumerated() {
            var current = [i+1] + Array(repeating: 0, count: y.count)
            for (j, cy) in y.enumerated() {
                current[j+1] = min(current[j]+1, previous[j+1]+1, previous[j] + (cx == cy ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
    static func voicedSeconds(_ frames: [StemSpeechFrame], in episode: OverlapEpisode) -> Double {
        frames.reduce(0) { total, frame in
            guard frame.probability >= 0.65 else { return total }
            return total + max(0, min(frame.end, episode.end)-max(frame.start, episode.start))
        }
    }

    private static func merged(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
        let values = intervals.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > $0.0 }
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard var current = values.first else { return [] }
        var output: [(Double, Double)] = []
        let tolerance = 1.0 / 16000
        for value in values.dropFirst() {
            if value.0 <= current.1 + tolerance {
                current.1 = max(current.1, value.1)
            } else {
                output.append(current); current = value
            }
        }
        output.append(current)
        return output
    }

    private static func intersections(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> [(Double, Double)] {
        var i = 0, j = 0
        let aa = merged(a), bb = merged(b)
        var output: [(Double, Double)] = []
        while i < aa.count && j < bb.count {
            let left = max(aa[i].0, bb[j].0), right = min(aa[i].1, bb[j].1)
            if right > left { output.append((left, right)) }
            if aa[i].1 < bb[j].1 { i += 1 } else { j += 1 }
        }
        return merged(output)
    }

    private static func duration(_ intervals: [(Double, Double)]) -> Double {
        merged(intervals).reduce(0) { $0 + max(0, $1.1-$1.0) }
    }

    private static func vadIntervals(_ frames: [StemSpeechFrame], within episode: OverlapEpisode) -> [(Double, Double)] {
        merged(frames.compactMap { frame in
            guard frame.probability >= 0.65 else { return nil }
            let left = max(frame.start, episode.start), right = min(frame.end, episode.end)
            return right > left ? (left, right) : nil
        })
    }

    private static func textIntervals(_ rows: [Caption], lane: Int) -> [(Double, Double)] {
        merged(rows.filter { $0.separationLane == lane }.flatMap { row in
            row.timedTextSpans.compactMap { span in span.isValid ? (span.start, span.end) : nil }
        })
    }
    static func clipped(_ rows: [Caption], to episode: OverlapEpisode) -> [Caption] {
        let tolerance = 1.0 / 16000
        return rows.compactMap { row in
            let intersecting = row.timedTextSpans.filter { span in
                span.isValid && min(span.end, episode.end) > max(span.start, episode.start)
            }
            guard !intersecting.isEmpty else { return nil }

            // Do not pull context text into the overlap by clamping only its timestamp. If
            // Apple gives one timing run that straddles the episode boundary, the text cut is
            // unknowable; reject that row and preserve Primary instead of inventing it.
            guard intersecting.allSatisfy({
                $0.start >= episode.start - tolerance && $0.end <= episode.end + tolerance
            }) else { return nil }

            let spans = intersecting.sorted {
                if $0.utf16Start == $1.utf16Start { return $0.utf16End < $1.utf16End }
                return $0.utf16Start < $1.utf16Start
            }
            guard let first = spans.first, let last = spans.last,
                  first.utf16Start >= 0, last.utf16End <= row.source.utf16.count else { return nil }
            var cursor = first.utf16Start
            for span in spans {
                guard span.utf16Start == cursor, span.utf16End > span.utf16Start else { return nil }
                cursor = span.utf16End
            }
            let lo = first.utf16Start, hi = cursor
            guard hi > lo else { return nil }

            let ns = row.source as NSString
            let raw = ns.substring(with: NSRange(location: lo, length: hi-lo))
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SentenceBoundary.hasSemanticContent(text) else { return nil }
            // A trimming operation changes the owning string's UTF-16 origin.
            // Intersect timed spans with the trimmed range BEFORE rebasing them.
            // Otherwise a span covering leading/trailing whitespace can extend
            // beyond `result.source`, even after acceptance and UI replacement.
            let leadingTrim = String(raw.prefix { $0.isWhitespace }).utf16.count
            let keptLo = lo + leadingTrim
            let keptHi = keptLo + text.utf16.count
            guard keptHi <= hi else { return nil }

            var result = row
            result.source = text
            result.start = spans.map(\.start).min() ?? episode.start
            result.end = spans.map(\.end).max() ?? episode.end
            guard result.start >= episode.start - tolerance,
                  result.end <= episode.end + tolerance,
                  result.end > result.start else { return nil }
            result.timedTextSpans = spans.compactMap { span -> TimedTextSpan? in
                let startOffset = max(span.utf16Start, keptLo)
                let endOffset = min(span.utf16End, keptHi)
                guard endOffset > startOffset else { return nil }
                return TimedTextSpan(utf16Start: startOffset-keptLo, utf16End: endOffset-keptLo,
                                     start: span.start, end: span.end)
            }
            guard !result.timedTextSpans.isEmpty else { return nil }
            return result
        }
    }
    static func accepted(_ result: SeparatedSpeechResult, target: SeparationTarget) throws -> [Caption] {
        guard target.isValid, result.speechFrames.count == 2 else {
            throw AppFailure.message("분리 결과의 시간 범위가 유효하지 않습니다.")
        }
        let rows = clipped(result.rows, to: target.episode)
        let lane0 = rows.filter { $0.separationLane == 0 }.map(\.source).joined()
        let lane1 = rows.filter { $0.separationLane == 1 }.map(\.source).joined()
        guard SentenceBoundary.hasSemanticContent(lane0), SentenceBoundary.hasSemanticContent(lane1) else {
            throw AppFailure.message("overlap 구간에서 두 화자의 분리 자막을 모두 확인하지 못했습니다.")
        }
        guard similarity(lane0, lane1) < 0.82 else {
            throw AppFailure.message("두 분리 자막이 지나치게 유사하여 crosstalk 가능성 때문에 원본을 유지합니다.")
        }

        // Acceptance requires temporal co-evidence, not merely "some VAD somewhere"
        // plus "some text somewhere" in the episode. For each lane, intersect its
        // VAD-positive frames with its Apple timed-text support. Then require a real
        // simultaneous interval between the two lanes as evidence of two-speaker overlap.
        let minimumVoice = max(0.12, min(0.50, target.episode.duration * 0.25))
        var supported: [[(Double, Double)]] = []
        for lane in 0..<2 {
            let vad = vadIntervals(result.speechFrames[lane], within: target.episode)
            let text = textIntervals(rows, lane: lane)
            let joint = intersections(vad, text)
            guard duration(joint) >= minimumVoice else {
                throw AppFailure.message("분리 stem의 VAD와 자막 시간 근거가 일치하지 않아 원본을 유지합니다.")
            }
            supported.append(joint)
        }
        let simultaneous = duration(intersections(supported[0], supported[1]))
        let minimumSimultaneous = max(0.08, min(0.25, target.episode.duration * 0.15))
        guard simultaneous >= minimumSimultaneous else {
            throw AppFailure.message("두 분리 stem의 동시 음성 근거가 부족하여 원본을 유지합니다.")
        }
        return rows
    }
}

struct SeparationLaneMapper {
    private static func voicedSeconds(_ frames: [StemSpeechFrame], start: Double, end: Double) -> Double {
        frames.reduce(0) { total, frame in
            guard frame.probability >= 0.65 else { return total }
            return total + max(0, min(frame.end, end)-max(frame.start, start))
        }
    }

    static func mapping(rows: [Caption], speechFrames: [[StemSpeechFrame]], episode: OverlapEpisode,
                        timeline: SpeechTimeline) -> [Int: LaneSpeakerIdentity] {
        guard speechFrames.count == 2 else { return [:] }
        // Separator lanes have no stable cross-epoch identity. Reject mapping
        // whenever the overlap itself or the accepted anchor votes span more
        // than one recurrent diarizer identity namespace.
        guard let overlapFrames = timeline.covering(start: episode.start, end: episode.end),
              let overlapEpoch = overlapFrames.first?.identityEpoch,
              overlapFrames.allSatisfy({ $0.identityEpoch == overlapEpoch }) else { return [:] }
        var votes: [Int: [LaneSpeakerIdentity: Double]] = [:]
        for row in rows {
            guard let lane = row.separationLane else { continue }
            for span in row.timedTextSpans where span.isValid {
                // Only non-overlap context can identify a local separator lane as a
                // persistent live-diarizer speaker. Never infer identity inside overlap.
                // A transcript alone is not enough: require VAD support on THIS stem and
                // dominance over the opposite stem so crosstalk text cannot vote a lane
                // onto the wrong global speaker.
                guard span.end <= episode.start || span.start >= episode.end,
                      let evidence = timeline.confidentSingleSpeaker(start: span.start, end: span.end),
                      evidence.epoch == overlapEpoch else { continue }
                let own = voicedSeconds(speechFrames[lane], start: span.start, end: span.end)
                let other = voicedSeconds(speechFrames[1-lane], start: span.start, end: span.end)
                guard own >= 0.08, own >= other*1.5, own-other >= 0.04 else { continue }
                votes[lane, default: [:]][LaneSpeakerIdentity(epoch: evidence.epoch, slot: evidence.slot), default: 0] += min(evidence.seconds, own)
            }
        }
        var chosen: [Int: (identity: LaneSpeakerIdentity, seconds: Double, total: Double)] = [:]
        for (lane, slots) in votes {
            let total = slots.values.reduce(0, +)
            guard let best = slots.max(by: { $0.value < $1.value }), best.value >= 0.30,
                  total > 0, best.value/total >= 0.80 else { continue }
            chosen[lane] = (best.key, best.value, total)
        }
        if let a = chosen[0], let b = chosen[1], a.identity == b.identity {
            return [:]
        }
        return chosen.mapValues(\.identity)
    }

    static func applying(_ mapping: [Int: LaneSpeakerIdentity], to rows: [Caption]) -> [Caption] {
        rows.map { input in
            var row = input
            let identity = row.separationLane.flatMap { mapping[$0] }
            row.speaker = identity?.slot
            if let identity {
                row.speakerSpans = row.timedTextSpans.map {
                    SpeakerSpan(utf16Start: $0.utf16Start, utf16End: $0.utf16End,
                                start: $0.start, end: $0.end, speaker: identity.slot,
                                confidentSpeech: $0.duration, overlap: true, identityEpoch: identity.epoch)
                }
            } else {
                row.speakerSpans = row.timedTextSpans.map {
                    SpeakerSpan(utf16Start: $0.utf16Start, utf16End: $0.utf16End,
                                start: $0.start, end: $0.end, speaker: nil,
                                confidentSpeech: $0.duration, overlap: true)
                }
            }
            return row
        }
    }
}

struct SeparationDiagnostics: Codable, Sendable {
    var status = "분리 모델 미연결 · 혼합음 STT 유지"
    var attempted = 0
    var completed = 0
    var skipped = 0
    var failures = 0
    var overloadStops = 0
    var busy = false
    var lastTargetStart: Double?
    var lastTargetEnd: Double?
    var lastInferenceStart: Double?
    var lastInferenceEnd: Double?
    var lastRejectReason: String?
}

// A cancelled Core ML call can outlive its capture. Hold one process-wide lease
// until that task exits so Stop→Start cannot stack native separation workloads.
@MainActor
enum SeparationWorkLease {
    private static var owner: UUID?
    static func acquire(_ id: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = id; return true
    }
    static func release(_ id: UUID) { if owner == id { owner = nil } }
}

@MainActor
final class LiveSeparationPass {
    private struct AttemptKey: Hashable {
        var row: UUID
        var startSample: Int64
        var endSample: Int64
    }
    private struct PendingIdentity {
        var ids: [UUID]
        var rows: [Caption]
        var speechFrames: [[StemSpeechFrame]]
        var episode: OverlapEpisode
    }

    private let processor = SeparationProcessor()
    private let modelURL: URL?
    private let currentRows: () -> [Caption]
    private let currentTimeline: () -> SpeechTimeline
    private let deliver: (Caption, OverlapEpisode, [Caption]) -> [UUID]
    private let remap: ([UUID], [Int: LaneSpeakerIdentity]) -> Void
    private var audio = SeparationAudioWindow()
    private var attempted: Set<AttemptKey> = []
    private var pendingIdentity: [PendingIdentity] = []
    private var task: Task<Void, Never>?
    private var prepared = false
    private var closed = false
    private var generation = UUID()
    private var startedAt: Double?
    private var pressureSince: Double?
    private(set) var diagnostics = SeparationDiagnostics()

    init(modelURL: URL? = Bundle.main.url(forResource: "Separator", withExtension: "mlmodelc", subdirectory: "Separation"),
         currentRows: @escaping () -> [Caption],
         currentTimeline: @escaping () -> SpeechTimeline,
         deliver: @escaping (Caption, OverlapEpisode, [Caption]) -> [UUID],
         remap: @escaping ([UUID], [Int: LaneSpeakerIdentity]) -> Void) {
        self.modelURL = modelURL
        self.currentRows = currentRows
        self.currentTimeline = currentTimeline
        self.deliver = deliver
        self.remap = remap
        if modelURL != nil { diagnostics.status = "분리 모델 있음 · 동시발화 대기 (실기 미검증)" }
    }
    func offer(_ chunk: PCMChunk) {
        guard modelURL != nil, !closed else { return }
        audio.append(chunk)
    }

    static func target(for row: Caption, episode: OverlapEpisode) -> SeparationTarget? {
        guard row.isFinal, row.separationGroup == nil, row.end > row.start,
              row.end-row.start <= 20, episode.isValid,
              episode.start >= row.start - 1.0/16000, episode.end <= row.end + 1.0/16000 else { return nil }
        // Do not spend Core ML/STT work when Primary has no sufficiently local Apple
        // text timing from which an overlap-only replacement can be made safely.
        let mapped = row.timedTextSpans.filter { span in
            guard span.isValid else { return false }
            let overlap = max(0, min(span.end, episode.end)-max(span.start, episode.start))
            guard overlap > 0 else { return false }
            let midpoint = (span.start+span.end)/2
            return (midpoint >= episode.start-0.05 && midpoint <= episode.end+0.05) || overlap/span.duration >= 0.5
        }
        guard !mapped.isEmpty else { return nil }
        let mappedStart = mapped.map(\.start).min() ?? episode.start
        let mappedEnd = mapped.map(\.end).max() ?? episode.end
        guard mappedEnd-mappedStart <= max(episode.duration + 0.8, episode.duration*2.5) else { return nil }
        // The model still gets context, but only this episode fragment is eligible for
        // replacement. A global episode may cross an NLTokenizer sentence boundary;
        // duration gating happened BEFORE this row-local intersection.
        let desired = 4.0
        var left = max(row.start, episode.start - 1.5)
        var right = min(row.end, episode.end + 1.5)
        if right-left < desired {
            let needLeft = min(desired-(right-left), left-row.start)
            left -= needLeft
            right = min(row.end, right + max(0, desired-(right-left)))
            if right-left < desired { left = max(row.start, left-(desired-(right-left))) }
        }
        let value = SeparationTarget(episode: episode, inferenceStart: left, inferenceEnd: right)
        return value.isValid ? value : nil
    }
    static func target(for row: Caption, timeline: SpeechTimeline) -> SeparationTarget? {
        // Test/helper path: a row-local query cannot prove an open tail. Require a
        // closed global episode whose confirmed portion intersects this row.
        let start = max(0, row.start-2)
        let end = max(row.end, timeline.latestEnd ?? row.end)
        for episode in timeline.overlapEpisodes(start: start, end: end).reversed() {
            let fragment = OverlapEpisode(start: max(row.start, episode.start), end: min(row.end, episode.end))
            if fragment.isValid, let target = target(for: row, episode: fragment) { return target }
        }
        return nil
    }
    static func eligible(_ row: Caption, timeline: SpeechTimeline) -> Bool { target(for: row, timeline: timeline) != nil }
    private func key(row: Caption, episode: OverlapEpisode) -> AttemptKey {
        .init(row: row.id,
              startSample: Int64((episode.start*16000).rounded()),
              endSample: Int64((episode.end*16000).rounded()))
    }

    private func refreshPendingIdentity() {
        guard !pendingIdentity.isEmpty else { return }
        let timeline = currentTimeline()
        let visible = Set(currentRows().map(\.id))
        var retained: [PendingIdentity] = []
        for pending in pendingIdentity {
            guard pending.ids.contains(where: { visible.contains($0) }) else { continue }
            let mapping = SeparationLaneMapper.mapping(rows: pending.rows, speechFrames: pending.speechFrames,
                                                       episode: pending.episode, timeline: timeline)
            if mapping.count == 2, Set(mapping.values).count == 2 {
                remap(pending.ids, mapping)
            } else {
                retained.append(pending)
            }
        }
        pendingIdentity = Array(retained.suffix(32))
    }

    private func candidate(rows: [Caption], timeline: SpeechTimeline, includeOpenTail: Bool)
        -> (Caption, SeparationTarget, AttemptKey)? {
        let eligibleRows = rows.filter { $0.isFinal && $0.separationGroup == nil }
        guard let start = eligibleRows.map(\.start).min(), let rowEnd = eligibleRows.map(\.end).max() else { return nil }
        let queryEnd = max(rowEnd, timeline.latestEnd ?? rowEnd)
        let episodes = timeline.overlapEpisodes(start: start, end: queryEnd, includeOpenTail: includeOpenTail)
        // Global episodes are duration-gated before row intersection. This preserves a
        // valid overlap that crosses a semantic sentence boundary.
        for episode in episodes.reversed() {
            for row in eligibleRows.reversed() {
                let fragment = OverlapEpisode(start: max(row.start, episode.start), end: min(row.end, episode.end))
                guard fragment.isValid else { continue }
                let k = key(row: row, episode: fragment)
                guard !attempted.contains(k) else { continue }
                if let target = Self.target(for: row, episode: fragment) { return (row, target, k) }
            }
        }
        return nil
    }

    func consider(fastBacklog: Double, endOfInput: Bool = false) {
        guard let modelURL, !closed else { return }
        refreshPendingIdentity()
        let now = ProcessInfo.processInfo.systemUptime
        if fastBacklog >= 0.75 {
            if pressureSince == nil { pressureSince = now }
            if now - (pressureSince ?? now) >= 1 { disable("빠른 STT 지연 · 이번 실행의 분리 중단") }
            return
        }
        pressureSince = nil
        if diagnostics.busy {
            if let startedAt, now-startedAt > 8 { disable("분리 처리 시간 초과 · 원본 유지") }
            return
        }

        let rows = currentRows()
        let timeline = currentTimeline()
        guard let (original, target, attemptKey) = candidate(rows: rows, timeline: timeline,
                                                             includeOpenTail: endOfInput) else { return }
        diagnostics.lastTargetStart = target.episode.start
        diagnostics.lastTargetEnd = target.episode.end
        diagnostics.lastInferenceStart = target.inferenceStart
        diagnostics.lastInferenceEnd = target.inferenceEnd
        diagnostics.lastRejectReason = nil

        guard let chunks = audio.covering(start: target.inferenceStart, end: target.inferenceEnd) else {
            if attempted.count >= 2048 { attempted.removeAll(keepingCapacity: true) }
            attempted.insert(attemptKey)
            diagnostics.skipped += 1
            diagnostics.lastRejectReason = "overlap inference PCM 없음"
            return
        }
        let lease = UUID()
        guard SeparationWorkLease.acquire(lease) else {
            diagnostics.status = "이전 분리 작업 정리 대기 · 빠른 STT 유지"; return
        }
        if attempted.count >= 2048 { attempted.removeAll(keepingCapacity: true) }
        attempted.insert(attemptKey)
        diagnostics.attempted += 1; diagnostics.busy = true
        diagnostics.status = prepared ? "overlap 구간 분리 중 · 빠른 STT 유지" : "분리 모델/VAD 준비 중 · 빠른 STT 유지"
        // Preparation is part of the same bounded optional job. Previously startedAt was
        // nil until preparation finished, so a stalled Core ML/VAD load had no live watchdog.
        startedAt = now
        let request = generation
        task = Task(priority: .utility) { [weak self] in
            defer { SeparationWorkLease.release(lease) }
            guard let self else { return }
            defer {
                if request == self.generation {
                    self.diagnostics.busy = false; self.startedAt = nil; self.task = nil
                }
            }
            do {
                if !self.prepared {
                    try await self.processor.prepare(modelURL)
                    try Task.checkCancellation()
                    self.prepared = true
                }
                guard !self.closed, request == self.generation else { return }
                let separated = try await self.processor.process(chunks, start: target.inferenceStart, end: target.inferenceEnd)
                try Task.checkCancellation()
                try SeparationAcceptance.validateStemIndependence(separated, in: target.episode)
                let detector = try await self.processor.speechDetector()
                let raw = try await SeparatedSpeechExperiment().transcribe(separated, language: original.language, detector: detector)
                try Task.checkCancellation()
                let acceptedRaw = try SeparationAcceptance.accepted(raw, target: target)
                // Identity is a DELIVERY-TIME decision. Use the newest authoritative
                // timeline, not the schedule-time value snapshot captured before model/STT.
                let laneMap = SeparationLaneMapper.mapping(rows: raw.rows, speechFrames: raw.speechFrames,
                                                           episode: target.episode,
                                                           timeline: self.currentTimeline())
                let accepted = SeparationLaneMapper.applying(laneMap, to: acceptedRaw)
                guard !self.closed, request == self.generation else { return }
                let ids = self.deliver(original, target.episode, accepted)
                if !ids.isEmpty {
                    self.diagnostics.completed += 1
                    self.diagnostics.lastRejectReason = nil
                    self.diagnostics.status = "overlap 구간만 분리 반영 · 다음 동시발화 대기"
                    if laneMap.count < 2 {
                        self.pendingIdentity.append(.init(ids: ids, rows: raw.rows,
                            speechFrames: raw.speechFrames, episode: target.episode))
                        self.pendingIdentity = Array(self.pendingIdentity.suffix(32))
                    }
                } else {
                    self.diagnostics.skipped += 1
                    self.diagnostics.lastRejectReason = "Primary 변경 또는 overlap text-time 매핑 불충분"
                    self.diagnostics.status = "overlap 부분 교체 불가 · Primary 원본 유지"
                }
            } catch {
                guard !self.closed, request == self.generation, !Task.isCancelled else { return }
                self.diagnostics.failures += 1
                self.diagnostics.lastRejectReason = error.localizedDescription
                self.diagnostics.status = "분리 보류 · " + error.localizedDescription
                if !self.prepared { self.closed = true; self.audio = SeparationAudioWindow() }
            }
        }
    }
    private func disable(_ message: String) {
        guard !closed else { return }
        diagnostics.overloadStops += 1; diagnostics.status = message
        stop()
    }
    func finish() async {
        guard modelURL != nil, !closed else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let request = generation
        while !closed {
            if Task.isCancelled || request != generation { stop(); return }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                disable("입력 종료 후 분리 대기 시간 초과 · 원본 유지"); return
            }
            let previousAttempts = attempted.count
            // Re-read rows/timeline after EVERY completed replacement. A prior episode can
            // split the original caption; a frozen EOF snapshot would make subsequent
            // episodes fail the stale-original guard.
            consider(fastBacklog: 0, endOfInput: true)
            if closed { return }
            if !diagnostics.busy {
                if attempted.count != previousAttempts { continue }
                refreshPendingIdentity()
                stop(); return
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { stop(); return }
        }
    }
    func clear() {
        generation = UUID()
        task?.cancel(); task = nil
        audio = SeparationAudioWindow(); attempted.removeAll(); pendingIdentity.removeAll()
        // Clear starts a fresh generation. An old cancellation-insensitive Core ML call
        // may still hold the process lease, but its timeout/generation must not close the
        // NEW pass generation while the user continues the same capture.
        diagnostics.busy = false; startedAt = nil; pressureSince = nil
        if !closed, modelURL != nil { diagnostics.status = "자막 초기화 · 동시발화 대기" }
    }
    func stop() {
        if !closed, modelURL != nil, diagnostics.overloadStops == 0 {
            diagnostics.status = diagnostics.busy
                ? "입력 종료 · 분리 취소 요청 (작업 정리 중)" : "입력 종료 · 분리 처리 종료"
        }
        closed = true; clear()
    }
}
