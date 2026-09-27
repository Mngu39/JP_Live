import Foundation
import CoreML
import AVFoundation

struct SeparatedAudio: Sendable {
    var start: Double
    var sampleRate: Double
    var stems: [[Float]]
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
        detector = try await FluidStemSpeechDetector()
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
                    detector: any StemSpeechDetector) async throws -> [Caption] {
        guard audio.stems.count == 2, audio.sampleRate == 16000, audio.start.isFinite,
              audio.start >= 0, !audio.stems[0].isEmpty,
              audio.stems[0].count == audio.stems[1].count,
              audio.stems.allSatisfy({ $0.allSatisfy { $0.isFinite } }) else {
            throw AppFailure.message("같은 길이의 16kHz 두 stem과 유효한 시작 시각이 필요합니다.")
        }
        // Complete VAD/leveling before opening either recognizer. If either stem
        // fails, no partial pair is delivered or silently substituted.
        var leveled: [[Float]] = []
        for stem in audio.stems {
            try Task.checkCancellation()
            let probabilities = try await detector.probabilities(stem)
            try Task.checkCancellation()
            leveled.append(try StemLeveling.process(stem, probabilities: probabilities))
        }
        let captureID = UUID()
        var rows: [Caption] = []
        var failures: [String] = []
        // Recognize stems sequentially: never add TWO simultaneous analyzers on
        // top of primary and quality STT. No partial results escape this method.
        for speaker in 0..<2 {
            let engine = AppleSpeechEngine()
            var transcript = TranscriptBuffer()
            transcript.begin(captureID: captureID, language: language)
            do {
                try Task.checkCancellation()
                try await engine.prepare(language: language, result: { text, final, start, end, finalizedThrough in
                    _ = transcript.receive(text, final: final, start: audio.start+start,
                        end: audio.start+end, speaker: speaker, now: ProcessInfo.processInfo.systemUptime,
                        finalizedThrough: finalizedThrough.map { audio.start + $0 })
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
                rows += completed
            } catch {
                let originalError = error
                do { try await engine.finish(aborting: true) }
                catch { throw AppFailure.message(originalError.localizedDescription + " · " + error.localizedDescription) }
                throw originalError
            }
        }
        let firstText = rows.filter { $0.speaker == 0 }.map(\.source).joined()
        let secondText = rows.filter { $0.speaker == 1 }.map(\.source).joined()
        guard firstText != secondText else { throw AppFailure.message("두 분리 결과가 같아 원본 자막을 유지합니다.") }
        return rows.sorted { $0.start < $1.start }
    }
}

struct SeparationDiagnostics: Codable {
    var status = "분리 모델 미연결 · 혼합음 STT 유지"
    var attempted = 0
    var completed = 0
    var skipped = 0
    var failures = 0
    var overloadStops = 0
    var busy = false
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
    private let processor = SeparationProcessor()
    private let modelURL: URL?
    private let deliver: (Caption, [Caption]) -> Bool
    private var audio = SeparationAudioWindow()
    private var attemptedIDs: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var prepared = false
    private var closed = false
    private var generation = UUID()
    private var startedAt: Double?
    private var pressureSince: Double?
    private(set) var diagnostics = SeparationDiagnostics()

    init(modelURL: URL? = Bundle.main.url(forResource: "Separator", withExtension: "mlmodelc", subdirectory: "Separation"),
         deliver: @escaping (Caption, [Caption]) -> Bool) {
        self.modelURL = modelURL; self.deliver = deliver
        if modelURL != nil { diagnostics.status = "분리 모델 있음 · 동시발화 대기 (실기 미검증)" }
    }
    func offer(_ chunk: PCMChunk) {
        guard modelURL != nil, !closed else { return }
        audio.append(chunk)
    }
    static func eligible(_ row: Caption, timeline: SpeechTimeline) -> Bool {
        guard row.isFinal, row.separationGroup == nil, row.end > row.start,
              row.end-row.start <= 20,
              let decisions = timeline.covering(start: row.start, end: row.end),
              decisions.allSatisfy({ $0.activeSpeakers <= 2 }) else { return false }
        var gate = OverlapGate()
        var overlap = false
        for decision in decisions {
            if gate.observe(activeSpeakers: decision.activeSpeakers, probability: decision.speechProbability) { overlap = true }
        }
        return overlap
    }
    func consider(_ rows: [Caption], timeline: SpeechTimeline, fastBacklog: Double) {
        guard let modelURL, !closed else { return }
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
        guard let original = rows.reversed().first(where: {
            !attemptedIDs.contains($0.id) && Self.eligible($0, timeline: timeline)
        }) else { return }
        guard let chunks = audio.covering(start: original.start, end: original.end) else {
            if attemptedIDs.count >= 2048 { attemptedIDs.removeAll(keepingCapacity: true) }
            attemptedIDs.insert(original.id)
            diagnostics.skipped += 1; return
        }
        let lease = UUID()
        guard SeparationWorkLease.acquire(lease) else {
            diagnostics.status = "이전 분리 작업 정리 대기 · 빠른 STT 유지"; return
        }
        if attemptedIDs.count >= 2048 { attemptedIDs.removeAll(keepingCapacity: true) }
        attemptedIDs.insert(original.id)
        diagnostics.attempted += 1; diagnostics.busy = true
        diagnostics.status = prepared ? "동시발화 분리 중 · 빠른 STT 유지" : "분리 모델 준비 중 · 빠른 STT 유지"
        startedAt = prepared ? now : nil
        let request = generation
        task = Task(priority: .utility) { [weak self] in
            defer { SeparationWorkLease.release(lease) }
            guard let self else { return }
            defer { self.diagnostics.busy = false; self.startedAt = nil; self.task = nil }
            do {
                if !self.prepared {
                    try await self.processor.prepare(modelURL)
                    try Task.checkCancellation()
                    self.prepared = true
                }
                guard !self.closed, request == self.generation else { return }
                self.startedAt = ProcessInfo.processInfo.systemUptime
                let separated = try await self.processor.process(chunks, start: original.start, end: original.end)
                try Task.checkCancellation()
                let detector = try await self.processor.speechDetector()
                let rows = try await SeparatedSpeechExperiment().transcribe(separated, language: original.language, detector: detector)
                try Task.checkCancellation()
                guard !self.closed, request == self.generation else { return }
                if self.deliver(original, rows) {
                    self.diagnostics.completed += 1; self.diagnostics.status = "분리 자막 반영 · 다음 동시발화 대기"
                } else {
                    self.diagnostics.skipped += 1; self.diagnostics.status = "원문 변경 또는 정렬 불일치 · 원본 유지"
                }
            } catch {
                guard !self.closed, request == self.generation, !Task.isCancelled else { return }
                self.diagnostics.failures += 1
                self.diagnostics.status = "분리 보류 · " + error.localizedDescription
                // Preparation failures must not trigger repeated model loads per row.
                if !self.prepared { self.closed = true; self.audio = SeparationAudioWindow() }
            }
        }
    }
    private func disable(_ message: String) {
        guard !closed else { return }
        diagnostics.overloadStops += 1; diagnostics.status = message
        stop()
    }
    // Natural EOF arrives before SpeechAnalyzer emits its final rows. Keep the
    // PCM window alive until both recognizers have finalized, then drain only
    // the recent eligible rows within one total budget (including preparation).
    // Do not await task.value: native prediction may not cooperate with cancel.
    func finish(rows: [Caption], timeline: SpeechTimeline) async {
        guard modelURL != nil, !closed else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let request = generation
        while !closed {
            if Task.isCancelled || request != generation { stop(); return }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                disable("입력 종료 후 분리 대기 시간 초과 · 원본 유지"); return
            }
            let previousAttempts = attemptedIDs.count
            consider(rows, timeline: timeline, fastBacklog: 0)
            if closed { return }
            if !diagnostics.busy {
                // Missing PCM consumes one candidate; continue to the next.
                if attemptedIDs.count != previousAttempts { continue }
                stop(); return
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { stop(); return }
        }
    }
    func clear() {
        generation = UUID(); task?.cancel(); audio = SeparationAudioWindow(); attemptedIDs.removeAll()
        // Keep busy until the cancelled native call really leaves the worker.
    }
    func stop() {
        if !closed, modelURL != nil, diagnostics.overloadStops == 0 {
            diagnostics.status = diagnostics.busy
                ? "입력 종료 · 분리 취소 요청 (작업 정리 중)" : "입력 종료 · 분리 처리 종료"
        }
        closed = true; clear()
    }
}
