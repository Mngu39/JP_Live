import Foundation
@preconcurrency import AVFoundation

protocol SpeechAnalysisProvider: Actor {
    // Finalized frame intervals relative to the first sample since reset.
    func process(_ mono: [Float], sampleRate: Double) async throws -> [SpeechDecision]
    func finish() async throws -> [SpeechDecision]
    func reset() async
}
protocol EnhancementProvider: Actor {
    func process(_ mono: [Float], sampleRate: Double, wetMix: Float) async throws -> [Float]
    func finish() async throws -> [Float]
    func recoverUnprocessed() async -> [Float]
}

private struct PendingAudio {
    var samples: [Float]
    var start: Double
    var decision: SpeechDecision? = nil
    var end: Double { start + Double(samples.count)/48000 }
}

actor AudioPreprocessor {
    private var floatConverter: StreamingPCMConverter?
    private var sourceClock = AudioSourceClock()
    private var closed = false
    private var leveler = SpeechLeveler()
    private var ring: [PCMChunk] = []
    private var pending: [PendingAudio] = []
    private var enhancementLedger: [PendingAudio] = []
    private var timeline = SpeechTimeline()
    private var analysisUpdates: [SpeechDecision] = []
    private var lastInputEnd: Double?
    private var analysisOrigin: Double?
    private var analysisGeneration = UUID()
    private var analysisTask: Task<Void, Never>?
    private var analysisInput: AsyncStream<([Float], Double)>.Continuation?
    private var warnings: [String] = []
    private var enhancementActive = false
    private var enhancementStartsAt: Double?
    private var analysis: (any SpeechAnalysisProvider)?
    private var enhancement: (any EnhancementProvider)?

    func setProviders(analysis: (any SpeechAnalysisProvider)?, enhancement: (any EnhancementProvider)?) async {
        analysisInput?.finish(); analysisTask?.cancel(); await analysisTask?.value
        self.analysis = analysis; self.enhancement = enhancement
        enhancementStartsAt = nil
        analysisOrigin = nil; analysisGeneration = UUID(); timeline = SpeechTimeline()
        analysisInput = nil; analysisTask = nil
        guard let analysis else { return }
        let generation = analysisGeneration
        // Optional diarization may lag without blocking STT. Absorb a short burst,
        // then degrade only the optional analysis path if it cannot keep up.
        let (stream, continuation) = AsyncStream<([Float], Double)>.makeStream(bufferingPolicy: .bufferingOldest(150))
        analysisInput = continuation
        analysisTask = Task {
            var origin: Double?
            do {
                for await (samples, base) in stream {
                    try Task.checkCancellation(); origin = base
                    let frames = try await analysis.process(samples, sampleRate: 48000)
                    try Task.checkCancellation()
                    guard self.analysisGeneration == generation else { return }
                    let shifted = frames.map { $0.shifted(by: base) }
                    self.timeline.append(shifted)
                    self.analysisUpdates.append(contentsOf: shifted)
                }
                try Task.checkCancellation()
                let tail = try await analysis.finish()
                try Task.checkCancellation()
                if let origin, self.analysisGeneration == generation {
                    let shifted = tail.map { $0.shifted(by: origin) }
                    self.timeline.append(shifted)
                    self.analysisUpdates.append(contentsOf: shifted)
                }
            } catch {
                guard !Task.isCancelled, self.analysisGeneration == generation else { return }
                self.disableAnalysis("화자 분석 오류 · 기본 STT 유지")
            }
        }
    }
    // Only the serial input loop calls this, between process calls. Prepared
    // providers are fresh and never receive already-emitted PCM retroactively.
    func installPrepared(analysis candidate: (any SpeechAnalysisProvider)?, enhancement enhancer: (any EnhancementProvider)?) async {
        if let candidate, analysis == nil {
            await setProviders(analysis: candidate, enhancement: enhancement)
            // setProviders clears the origin; the FIRST following PCM supplies it.
            leveler = SpeechLeveler()
        }
        if let enhancer, enhancement == nil {
            enhancement = enhancer
            // Analysis may still hold older PCM. Keep that backlog on its old path.
            enhancementStartsAt = lastInputEnd
        }
    }
    private func warn(_ text: String) { if !warnings.contains(text) { warnings.append(text) } }
    private func disableAnalysis(_ message: String) {
        analysisInput?.finish(); analysisInput = nil; analysisTask?.cancel(); warn(message)
    }
    func process(_ chunk: PCMChunk) async throws -> ([PCMChunk], AudioMetrics) {
        var emitted: [PCMChunk] = []
        guard !closed else { throw AppFailure.message("종료된 오디오 파이프라인입니다.") }
        guard chunk.buffer.frameLength > 0 else { return ([], AudioMetrics(warnings: warnings)) }
        let boundary = try sourceClock.accept(time: chunk.time, frames: chunk.buffer.frameLength,
                                              rate: chunk.buffer.format.sampleRate)
        let channels = max(1, min(2, chunk.buffer.format.channelCount))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            channels: channels, interleaved: false) else { throw AppFailure.message("PCM 형식 생성 실패") }
        if boundary || floatConverter?.inputFormat != chunk.buffer.format {
            // Flush converted PCM BEFORE finishing the analysis stream. Old-segment
            // tails must not inherit the next segment's origin or speaker labels.
            emitted += try await finishSegment(cancelAnalysis: false)
            await analysis?.reset()
            await setProviders(analysis: analysis, enhancement: enhancement)
            floatConverter = try StreamingPCMConverter(from: chunk.buffer.format, to: format, origin: chunk.time)
            leveler = SpeechLeveler(); ring = []
        }
        lastInputEnd = sourceClock.end
        var value = AudioMetrics(time: chunk.time, warnings: warnings)
        for converted in try floatConverter?.convert(chunk.buffer) ?? [] {
            value = try enqueue(converted)
        }
        emitted += await drain(force: false)
        let decision = emitted.last?.decision
        value.time = emitted.last?.time ?? chunk.time
        value.gainDB = 20*log10(Double(leveler.gain))
        value.speechProbability = decision?.speechProbability
        value.activeSpeakers = decision?.activeSpeakers; value.speakerSlot = decision?.speakerSlot
        value.warnings = warnings
        return (emitted, value)
    }
    private func enqueue(_ chunk: PCMChunk) throws -> AudioMetrics {
        let pcm = chunk.buffer
        let channels = pcm.format.channelCount
        guard let data = pcm.floatChannelData else { throw AppFailure.message("Float PCM이 필요합니다.") }
        let n = Int(pcm.frameLength)
        let left = Array(UnsafeBufferPointer(start: data[0], count: n))
        let right = channels == 2 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : left
        ring.append(PCMChunk(buffer: pcm, time: chunk.time)); ring.removeAll { $0.time < chunk.time-12 }
        let mono = StereoSelection.mono(left: left, right: right)
        let rms = sqrt(mono.reduce(Float(0)) { $0+$1*$1 } / Float(max(n, 1)))
        let peak = mono.map(abs).max() ?? 0
        if let analysisInput {
            if analysisOrigin == nil { analysisOrigin = chunk.time }
            switch analysisInput.yield((mono, analysisOrigin ?? chunk.time)) {
            case .dropped: disableAnalysis("화자 분석 큐 초과 · 기본 STT 유지")
            case .terminated: disableAnalysis("화자 분석 종료 · 기본 STT 유지")
            case .enqueued: break
            @unknown default: break
            }
        }
        // Keep 10 ms render slices, but never hold them waiting for diarization.
        // Speaker analysis is a parallel metadata path and may arrive later.
        for offset in stride(from: 0, to: mono.count, by: 480) {
            let count = min(480, mono.count-offset)
            pending.append(PendingAudio(samples: Array(mono[offset..<offset+count]),
                start: chunk.time+Double(offset)/48000))
        }
        return AudioMetrics(time: chunk.time,
            rmsDB: 20*log10(Double(max(rms, 0.000001))), peakDB: 20*log10(Double(max(peak, 0.000001))))
    }
    private func drain(force: Bool) async -> [PCMChunk] {
        var outputs: [PCMChunk] = []
        while var frame = pending.first {
            // Opportunistically use analysis that has already arrived, but never wait for
            // it. This keeps the STT transport real-time while FluidAudio continues in
            // parallel and publishes speaker metadata through takeAnalysisUpdates().
            frame.decision = timeline.decision(start: frame.start, end: frame.end)
            pending.removeFirst()
            let enhancementEligible = enhancementStartsAt.map { frame.start >= $0-1.0/48000 } ?? true
            let mix: Float = enhancementEligible && frame.decision?.activeSpeakers == 1 && (frame.decision?.speechProbability ?? 0) >= 0.65 ? 0.35 : 0
            if mix > 0, let enhancement {
                enhancementLedger.append(frame); enhancementActive = true
                do {
                    guard enhancementLedger.reduce(0, { $0+$1.samples.count }) <= 48000 else {
                        throw AppFailure.message("음성 개선 출력 지연 초과")
                    }
                    let wet = try await enhancement.process(frame.samples, sampleRate: 48000, wetMix: mix)
                    outputs += try consumeEnhanced(wet)
                } catch {
                    _ = await enhancement.recoverUnprocessed()
                    outputs += recoverLedger()
                    enhancementActive = false; self.enhancement = nil
                    warn("음성 개선 오류 · 원본 처리로 전환")
                }
            } else {
                // No processHop or flush on dry-only stretches. At the boundary,
                // restore the still-buffered original tail, reset, then bypass.
                if enhancementActive {
                    _ = await enhancement?.recoverUnprocessed()
                    outputs += recoverLedger(); enhancementActive = false
                }
                outputs.append(render(frame))
            }
        }
        return outputs
    }
    private func render(_ frame: PendingAudio) -> PCMChunk {
        let singleSpeaker = frame.decision?.activeSpeakers == 1
        let samples = leveler.process(frame.samples,
            speechProbability: singleSpeaker ? frame.decision?.speechProbability : nil,
            allowUpwardGain: singleSpeaker,
            speakerSlot: singleSpeaker ? frame.decision?.speakerSlot : nil)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) } }
        return PCMChunk(buffer: buffer, time: frame.start, decision: frame.decision)
    }
    private func consumeEnhanced(_ samples: [Float]) throws -> [PCMChunk] {
        guard samples.allSatisfy(\.isFinite), samples.count <= enhancementLedger.reduce(0, { $0+$1.samples.count })
        else { throw AppFailure.message("음성 개선 출력 길이/값 오류") }
        var cursor = 0; var outputs: [PCMChunk] = []
        while cursor < samples.count {
            var original = enhancementLedger.removeFirst()
            let n = min(original.samples.count, samples.count-cursor)
            var value = original; value.samples = Array(samples[cursor..<cursor+n])
            outputs.append(render(value)); cursor += n
            original.samples.removeFirst(n); original.start += Double(n)/48000
            if !original.samples.isEmpty { enhancementLedger.insert(original, at: 0) }
        }
        return outputs
    }
    private func recoverLedger() -> [PCMChunk] {
        let frames = enhancementLedger; enhancementLedger = []
        return frames.map { render($0) }
    }
    func takeAnalysisUpdates() -> [SpeechDecision] {
        let updates = analysisUpdates
        analysisUpdates.removeAll(keepingCapacity: true)
        return updates
    }
    func finish(cancelAnalysis: Bool = false) async throws -> [PCMChunk] {
        guard !closed else { return [] }
        closed = true
        return try await finishSegment(cancelAnalysis: cancelAnalysis)
    }
    func cancel() async {
        closed = true
        analysisInput?.finish(); analysisInput = nil; analysisTask?.cancel()
        await analysisTask?.value; analysisTask = nil
        _ = await enhancement?.recoverUnprocessed()
        pending = []; enhancementLedger = []; floatConverter = nil; ring = []; analysisUpdates = []
    }
    private func finishSegment(cancelAnalysis: Bool) async throws -> [PCMChunk] {
        for tail in try floatConverter?.flush() ?? [] { _ = try enqueue(tail) }
        floatConverter = nil
        analysisInput?.finish(); analysisInput = nil
        if cancelAnalysis || Task.isCancelled { analysisTask?.cancel() }
        await analysisTask?.value; analysisTask = nil
        var outputs = await drain(force: true)
        if enhancementActive, let enhancement {
            do {
                let tail = try await enhancement.finish()
                outputs += try consumeEnhanced(tail)
            }
            catch { _ = await enhancement.recoverUnprocessed(); warn("음성 개선 종료 오류 · 원본 tail 유지") }
            // Also preserve any tail a provider failed to return.
            outputs += recoverLedger(); enhancementActive = false
        }
        return outputs
    }
}
