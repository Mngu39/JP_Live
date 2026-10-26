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
    var enqueuedAt: Double
    var decision: SpeechDecision? = nil
    var end: Double { start + Double(samples.count)/48000 }
}

private struct AnalysisPCM {
    var samples: [Float]
    var start: Double
    var end: Double { start + Double(samples.count)/48000 }
}


private actor AnalysisWaitLatch {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value); waiter = nil
    }
    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result { continuation.resume(returning: result) }
            else { waiter = continuation }
        }
    }
}

private func waitForAnalysisTask(_ task: Task<Void, Never>, seconds: Double) async -> Bool {
    let latch = AnalysisWaitLatch()
    Task.detached(priority: .utility) { await task.value; await latch.resolve(true) }
    Task.detached(priority: .utility) {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        await latch.resolve(false)
    }
    return await latch.wait()
}

actor AudioPreprocessor {
    private var floatConverter: StreamingPCMConverter?
    private var sourceClock = AudioSourceClock()
    private var closed = false
    private var leveler = SpeechLeveler()
    // Recent mono PCM is retained so a required live diarizer that finishes model
    // preparation after capture has already started can backfill the beginning of the
    // session. 30 s is bounded (~5.8 MiB of Float mono) and covers normal warm-up.
    private var analysisRing: [AnalysisPCM] = []
    // Segments captured before a late live diarizer was installed. Keep source
    // discontinuities explicit so each segment can be backfilled after a reset instead
    // of compressing source time or discarding pre-boundary speech.
    private var archivedAnalysisSegments: [[AnalysisPCM]] = []
    private var pending: [PendingAudio] = []
    private var enhancementLedger: [PendingAudio] = []
    private var timeline = SpeechTimeline()
    private var analysisUpdates: [SpeechDecision] = []
    private var lastInputEnd: Double?
    private var analysisOrigin: Double?
    private var analysisGeneration = UUID()
    private var analysisTask: Task<Void, Never>?
    private var analysisRecoveryTask: Task<Void, Never>?
    private var analysisInput: AsyncStream<([Float], Double)>.Continuation?
    // A source/format discontinuity needs a fresh diarizer epoch, but is not a
    // model failure and must never consume the bounded *error* retry budget.
    private enum AnalysisRecoveryReason { case sourceBoundary, failure }
    private var analysisRecoveryPending: AnalysisRecoveryReason?
    private var analysisRecoveryToken: UUID?
    private var analysisRecoveryAttempts = 0
    private let maxAnalysisRecoveryAttempts = 2
    // Shared EOF budget for chained recovery, not a success-on-timeout signal.
    private let maxAnalysisWait: Double = 2
    private var warnings: [String] = []
    private var enhancementActive = false
    private var enhancementStartsAt: Double?
    private var analysis: (any SpeechAnalysisProvider)?
    private var enhancement: (any EnhancementProvider)?

    func setProviders(analysis: (any SpeechAnalysisProvider)?, enhancement: (any EnhancementProvider)?) async {
        // Invalidate any previously detached reset before installing new providers.
        analysisRecoveryToken = nil
        analysisRecoveryTask?.cancel(); analysisRecoveryTask = nil
        analysisInput?.finish(); analysisTask?.cancel(); await analysisTask?.value
        self.analysis = analysis; self.enhancement = enhancement
        enhancementStartsAt = nil
        analysisRecoveryPending = nil; analysisRecoveryAttempts = 0
        await startAnalysisStream(replayRecentPCM: false)
    }

    private func startAnalysisStream(replayRecentPCM: Bool) async {
        analysisInput?.finish(); analysisInput = nil
        if let task = analysisTask { task.cancel(); await task.value }
        analysisTask = nil
        analysisOrigin = nil; analysisGeneration = UUID(); timeline = SpeechTimeline()
        guard let analysis else { return }
        let generation = analysisGeneration
        let backfill: [[AnalysisPCM]]
        if replayRecentPCM {
            backfill = archivedAnalysisSegments + (analysisRing.isEmpty ? [] : [analysisRing])
            archivedAnalysisSegments.removeAll(keepingCapacity: true)
            analysisOrigin = analysisRing.first?.start
        } else { backfill = [] }
        // Diarization is metadata: Primary STT never waits for it. The bounded queue is
        // recoverable; middle-buffer loss is never silently accepted.
        let (stream, continuation) = AsyncStream<([Float], Double)>.makeStream(bufferingPolicy: .bufferingOldest(150))
        analysisInput = continuation
        analysisTask = Task {
            var origin: Double?
            do {
                if !backfill.isEmpty {
                    for (segmentIndex, segment) in backfill.enumerated() where !segment.isEmpty {
                        if segmentIndex > 0 { await analysis.reset() }
                        try Task.checkCancellation()
                        let base = segment[0].start
                        origin = base
                        var batch: [Float] = []
                        for item in segment {
                            if !batch.isEmpty && batch.count + item.samples.count > 48000 {
                                let frames = try await analysis.process(batch, sampleRate: 48000)
                                try Task.checkCancellation()
                                guard self.analysisGeneration == generation else { return }
                                let shifted = frames.map { $0.shifted(by: base) }
                                self.timeline.append(shifted); self.analysisUpdates.append(contentsOf: shifted)
                                batch.removeAll(keepingCapacity: true)
                            }
                            batch += item.samples
                        }
                        if !batch.isEmpty {
                            let frames = try await analysis.process(batch, sampleRate: 48000)
                            try Task.checkCancellation()
                            guard self.analysisGeneration == generation else { return }
                            let shifted = frames.map { $0.shifted(by: base) }
                            self.timeline.append(shifted); self.analysisUpdates.append(contentsOf: shifted)
                        }
                    }
                }
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
                self.requestAnalysisRecovery("화자 분석 오류 · 자동 복구 예약", reason: .failure)
            }
        }
    }

    // Only the serial input loop calls this, between process calls. A freshly prepared
    // diarizer receives the bounded recent PCM window before live PCM so early speech is
    // not permanently missing merely because model preparation finished late.
    func installPrepared(analysis candidate: (any SpeechAnalysisProvider)?, enhancement enhancer: (any EnhancementProvider)?) async {
        if let candidate, analysis == nil {
            self.analysis = candidate
            analysisRecoveryPending = nil; analysisRecoveryAttempts = 0
            await startAnalysisStream(replayRecentPCM: true)
            leveler = SpeechLeveler()
        }
        if let enhancer, enhancement == nil {
            enhancement = enhancer
            // Analysis may still hold older PCM. Keep that backlog on its old path.
            enhancementStartsAt = lastInputEnd
        }
    }

    private func requestAnalysisRecovery(_ message: String, reason: AnalysisRecoveryReason) {
        guard analysis != nil else { return }
        analysisInput?.finish(); analysisInput = nil
        analysisGeneration = UUID() // invalidate every late result from the retiring worker
        analysisTask?.cancel()
        // A genuine failure dominates a coalesced ordinary source boundary.
        // Repeated boundaries while a native reset is in flight are coalesced.
        if reason == .failure || analysisRecoveryPending == nil {
            analysisRecoveryPending = reason
        }
        warn(message)
    }

    // Recovery is deliberately non-blocking for Primary PCM. Native Core ML may
    // ignore cancellation: retire the previous worker in a detached reaper and
    // reset/replay recent PCM without holding the Primary path.
    private func beginAnalysisRecoveryIfNeeded() {
        guard let reason = analysisRecoveryPending,
              analysisRecoveryTask == nil, let analysis else { return }
        analysisRecoveryPending = nil
        let oldTask = analysisTask
        analysisTask = nil
        analysisInput?.finish(); analysisInput = nil
        if reason == .failure {
            if analysisRecoveryAttempts >= maxAnalysisRecoveryAttempts {
                self.analysis = nil
                analysisRecoveryToken = nil
                let reaper = oldTask
                Task.detached(priority: .utility) { await reaper?.value }
                warn("화자 분석 반복 실패 · 이번 세션 메타데이터 비활성")
                return
            }
            analysisRecoveryAttempts += 1
        }
        let token = UUID()
        analysisRecoveryToken = token
        analysisRecoveryTask = Task.detached(priority: .utility) { [weak self] in
            await oldTask?.value
            guard !Task.isCancelled else { return }
            await analysis.reset()
            guard !Task.isCancelled else { return }
            await self?.completeAnalysisRecovery(token: token)
        }
        warn(reason == .failure ? "화자 분석 자동 복구 수행" : "화자 분석 소스 경계 재설정 수행")
    }

    private func completeAnalysisRecovery(token: UUID) async {
        // A cancelled/replaced recovery must not clear a newer recovery's task
        // or install a stale analysis stream after provider replacement / Stop.
        guard analysisRecoveryToken == token else { return }
        analysisRecoveryToken = nil
        analysisRecoveryTask = nil
        guard !closed, analysis != nil else { return }
        if analysisRecoveryPending != nil {
            // Another source boundary/failure arrived while reset was in flight.
            // Never start the obsolete stream; replay the latest bounded PCM
            // after the next reset instead.
            beginAnalysisRecoveryIfNeeded()
        } else {
            await startAnalysisStream(replayRecentPCM: true)
        }
    }

    private func warn(_ text: String) { if !warnings.contains(text) { warnings.append(text) } }

    func process(_ chunk: PCMChunk) async throws -> ([PCMChunk], AudioMetrics) {
        var emitted: [PCMChunk] = []
        beginAnalysisRecoveryIfNeeded()
        guard !closed else { throw AppFailure.message("종료된 오디오 파이프라인입니다.") }
        guard chunk.buffer.frameLength > 0 else { return ([], AudioMetrics(warnings: warnings)) }
        let boundary = try sourceClock.accept(time: chunk.time, frames: chunk.buffer.frameLength,
                                              rate: chunk.buffer.format.sampleRate)
        let channels = max(1, min(2, chunk.buffer.format.channelCount))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            channels: channels, interleaved: false) else { throw AppFailure.message("PCM 형식 생성 실패") }
        if boundary || floatConverter?.inputFormat != chunk.buffer.format {
            // Render/conversion may cross a source boundary, but Primary must never wait
            // for a cancellation-insensitive diarizer worker. Archive pre-install PCM, or
            // asynchronously retire/reset an installed worker, then start the new segment.
            emitted += try await finishRenderSegment()
            if !analysisRing.isEmpty { archivedAnalysisSegments.append(analysisRing) }
            analysisRing = []
            if analysis != nil {
                requestAnalysisRecovery("화자 분석 소스 경계 · 자동 복구 예약", reason: .sourceBoundary)
                beginAnalysisRecoveryIfNeeded()
            }
            floatConverter = try StreamingPCMConverter(from: chunk.buffer.format, to: format, origin: chunk.time)
            leveler = SpeechLeveler()
        }
        lastInputEnd = sourceClock.end
        var value = AudioMetrics(time: chunk.time, warnings: warnings)
        for converted in try floatConverter?.convert(chunk.buffer) ?? [] {
            value = try enqueue(converted)
        }
        emitted += await drain()
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
        let mono = StereoSelection.mono(left: left, right: right)
        analysisRing.append(AnalysisPCM(samples: mono, start: chunk.time))
        let keepAfter = chunk.time + Double(n)/48000 - 30
        analysisRing.removeAll { $0.end < keepAfter }
        archivedAnalysisSegments = archivedAnalysisSegments.compactMap { segment in
            let kept = segment.filter { $0.end >= keepAfter }
            return kept.isEmpty ? nil : kept
        }
        let rms = sqrt(mono.reduce(Float(0)) { $0+$1*$1 } / Float(max(n, 1)))
        let peak = mono.map(abs).max() ?? 0
        if let analysisInput {
            if analysisOrigin == nil { analysisOrigin = chunk.time }
            switch analysisInput.yield((mono, analysisOrigin ?? chunk.time)) {
            case .dropped: requestAnalysisRecovery("화자 분석 큐 초과 · 자동 복구 예약", reason: .failure)
            case .terminated: requestAnalysisRecovery("화자 분석 입력 종료 · 자동 복구 예약", reason: .failure)
            case .enqueued: break
            @unknown default: break
            }
        }
        // Keep 10 ms render slices, but never hold them waiting for diarization.
        // Speaker analysis is a parallel metadata path and may arrive later.
        for offset in stride(from: 0, to: mono.count, by: 480) {
            let count = min(480, mono.count-offset)
            pending.append(PendingAudio(samples: Array(mono[offset..<offset+count]),
                start: chunk.time+Double(offset)/48000,
                enqueuedAt: ProcessInfo.processInfo.systemUptime))
        }
        return AudioMetrics(time: chunk.time,
            rmsDB: 20*log10(Double(max(rms, 0.000001))), peakDB: 20*log10(Double(max(peak, 0.000001))))
    }
    private func drain() async -> [PCMChunk] {
        var outputs: [PCMChunk] = []
        while var frame = pending.first {
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
        defer { closed = true }
        return try await finishSegment(cancelAnalysis: cancelAnalysis)
    }
    func cancel() async {
        closed = true
        analysisGeneration = UUID()
        analysisInput?.finish(); analysisInput = nil
        let retiring = analysisTask; analysisTask?.cancel(); analysisTask = nil
        analysisRecoveryToken = nil
        analysisRecoveryTask?.cancel(); analysisRecoveryTask = nil
        Task.detached(priority: .utility) { await retiring?.value }
        _ = await enhancement?.recoverUnprocessed()
        pending = []; enhancementLedger = []; floatConverter = nil
        analysisRing = []; archivedAnalysisSegments = []; analysisUpdates = []
    }
    private func finishRenderSegment() async throws -> [PCMChunk] {
        for tail in try floatConverter?.flush() ?? [] { _ = try enqueue(tail) }
        floatConverter = nil
        var outputs = await drain()
        if enhancementActive, let enhancement {
            do {
                let tail = try await enhancement.finish()
                outputs += try consumeEnhanced(tail)
            } catch {
                _ = await enhancement.recoverUnprocessed()
                warn("음성 개선 종료 오류 · 원본 tail 유지")
            }
            outputs += recoverLedger(); enhancementActive = false
        }
        return outputs
    }

    private func finishSegment(cancelAnalysis: Bool) async throws -> [PCMChunk] {
        for tail in try floatConverter?.flush() ?? [] { _ = try enqueue(tail) }
        floatConverter = nil

        if cancelAnalysis || Task.isCancelled {
            analysisGeneration = UUID()
            analysisInput?.finish(); analysisInput = nil
            let retiring = analysisTask; analysisTask?.cancel(); analysisTask = nil
            analysisRecoveryTask?.cancel(); analysisRecoveryTask = nil
            Task.detached(priority: .utility) { await retiring?.value }
        } else {
            beginAnalysisRecoveryIfNeeded()
            // A recovery can be superseded by another source boundary while
            // its native reset is running. Drain the chained recovery using one
            // overall EOF deadline; never wait a fresh 2 seconds for each reset.
            let recoveryDeadline = ProcessInfo.processInfo.systemUptime + maxAnalysisWait
            while let recovery = analysisRecoveryTask {
                let remaining = recoveryDeadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 || !(await waitForAnalysisTask(recovery, seconds: remaining)) {
                    analysisGeneration = UUID()
                    analysisRecoveryToken = nil
                    analysisRecoveryTask?.cancel(); analysisRecoveryTask = nil
                    self.analysis = nil
                    warn("화자 분석 EOF 복구 2초 초과 · Primary 종료 우선")
                    break
                }
            }
            analysisInput?.finish(); analysisInput = nil
            if let active = analysisTask {
                let completed = await waitForAnalysisTask(active, seconds: maxAnalysisWait)
                if !completed {
                    analysisGeneration = UUID()
                    active.cancel(); analysisTask = nil
                    self.analysis = nil
                    warn("화자 분석 EOF 종료 2초 초과 · Primary 종료 우선")
                } else { analysisTask = nil }
            }
        }

        var outputs = await drain()
        if enhancementActive, let enhancement {
            do {
                let tail = try await enhancement.finish()
                outputs += try consumeEnhanced(tail)
            }
            catch { _ = await enhancement.recoverUnprocessed(); warn("음성 개선 종료 오류 · 원본 tail 유지") }
            outputs += recoverLedger(); enhancementActive = false
        }
        return outputs
    }
}
