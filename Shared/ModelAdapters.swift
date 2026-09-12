import Foundation

struct PreparedOptionalProviders: Sendable {
    var analysis: (any SpeechAnalysisProvider)?
    var enhancement: (any EnhancementProvider)?
    var status: String
}

// Per-capture mailbox. Loaders never mutate the live pipeline or AppModel.
// Cancellation closes delivery immediately; stop never awaits a model download.
actor OptionalProviderPreparation {
    typealias AnalysisLoader = @Sendable () async throws -> any SpeechAnalysisProvider
    typealias EnhancementLoader = @Sendable () async throws -> any EnhancementProvider
    private var analysisTask: Task<Void, Never>?
    private var enhancementTask: Task<Void, Never>?
    private var readyAnalysis: (any SpeechAnalysisProvider)?
    private var readyEnhancement: (any EnhancementProvider)?
    private var analysisStatus = "화자 분석 미연결"
    private var enhancementStatus = "음성 개선 미연결"
    private var started = false
    private var closed = false

    func startAvailable() {
        var analysis: AnalysisLoader?
        var enhancement: EnhancementLoader?
        #if PHASE2 && canImport(FluidAudio)
        analysis = { let value = FluidSpeechAnalysis(); try await value.prepare(); return value }
        #endif
        #if PHASE2 && canImport(DeepFilterNetCoreML)
        enhancement = { let value = DeepFilterEnhancement(); try await value.prepare(); return value }
        #endif
        start(analysis: analysis, enhancement: enhancement)
    }
    func start(analysis: AnalysisLoader?, enhancement: EnhancementLoader?) {
        guard !started && !closed else { return }
        started = true
        if let analysis {
            analysisStatus = "화자 분석 준비 중 · 기본 STT 유지"
            analysisTask = Task.detached(priority: .utility) { [weak self] in
                do {
                    try Task.checkCancellation()
                    let value = try await analysis()
                    try Task.checkCancellation()
                    await self?.receivedAnalysis(value)
                } catch {
                    if !Task.isCancelled { await self?.failedAnalysis() }
                }
            }
        }
        if let enhancement {
            enhancementStatus = "음성 개선 준비 중 · 원본 유지"
            enhancementTask = Task.detached(priority: .utility) { [weak self] in
                do {
                    try Task.checkCancellation()
                    let value = try await enhancement()
                    try Task.checkCancellation()
                    await self?.receivedEnhancement(value)
                } catch {
                    if !Task.isCancelled { await self?.failedEnhancement() }
                }
            }
        }
    }
    private func receivedAnalysis(_ value: any SpeechAnalysisProvider) {
        guard !closed else { return }
        readyAnalysis = value; analysisTask = nil; analysisStatus = "화자 분석 준비됨"
    }
    private func receivedEnhancement(_ value: any EnhancementProvider) {
        guard !closed else { return }
        readyEnhancement = value; enhancementTask = nil; enhancementStatus = "음성 개선 준비됨 · 단일 화자 구간에 적용"
    }
    private func failedAnalysis() {
        guard !closed else { return }
        analysisTask = nil; analysisStatus = "화자 분석 준비 실패 · 기본 STT 유지"
    }
    private func failedEnhancement() {
        guard !closed else { return }
        enhancementTask = nil; enhancementStatus = "음성 개선 준비 실패 · 원본 유지"
    }
    func takeReady() -> PreparedOptionalProviders {
        defer { readyAnalysis = nil; readyEnhancement = nil }
        return PreparedOptionalProviders(analysis: readyAnalysis, enhancement: readyEnhancement,
            status: closed ? "입력 중지" : analysisStatus + " · " + enhancementStatus)
    }
    func cancel() {
        closed = true
        analysisTask?.cancel(); enhancementTask?.cancel()
        analysisTask = nil; enhancementTask = nil
        readyAnalysis = nil; readyEnhancement = nil
    }
}

#if canImport(FluidAudio)
import FluidAudio

actor FluidSpeechAnalysis: SpeechAnalysisProvider {
    private var diarizer: LSEENDDiarizer?
    private var elapsed: Double = 0
    private var epoch: Double = 0
    private var speakerBase = 0
    func reset() { diarizer?.reset(); elapsed = 0; epoch = 0; speakerBase += 10 }
    func prepare() async throws {
        var config = DiarizerTimelineConfig.default(numSpeakers: 10, frameDurationSeconds: 0.1)
        config.maxStoredFrames = 200
        config.storeSegments = false
        let diarizer = LSEENDDiarizer(timelineConfig: config)
        try await diarizer.initialize(variant: .dihard3, stepSize: .step100ms, computeUnits: .cpuOnly)
        self.diarizer = diarizer
    }
    func process(_ mono: [Float], sampleRate: Double) async throws -> [SpeechDecision] {
        guard let diarizer, sampleRate > 0 else { return [] }
        var frames: [SpeechDecision] = []
        // Local identity only. Renew recurrent state before the upstream one-hour validation bound.
        if elapsed-epoch >= 45*60 {
            if let update = try diarizer.finalizeSession() { frames += try decisions(update.chunkResult) }
            diarizer.reset(); epoch = elapsed; speakerBase += 10
        }
        elapsed += Double(mono.count)/sampleRate
        if let update = try diarizer.process(samples: mono, sourceSampleRate: sampleRate) {
            frames += try decisions(update.chunkResult)
        }
        return frames
    }
    func finish() async throws -> [SpeechDecision] {
        guard let update = try diarizer?.finalizeSession() else { return [] }
        return try decisions(update.chunkResult)
    }
    private func decisions(_ result: DiarizerChunkResult) throws -> [SpeechDecision] {
        guard let count = diarizer?.numSpeakers, count > 0,
              let hz = diarizer?.modelFrameHz, hz > 0,
              result.finalizedPredictions.count == result.finalizedFrameCount*count
        else { throw AppFailure.message("화자 분석 프레임 형식 오류") }
        var frames: [SpeechDecision] = []
        for index in 0..<result.finalizedFrameCount {
            let start = epoch + Double(result.startFrame+index)/hz
            let end = min(elapsed, epoch + Double(result.startFrame+index+1)/hz)
            guard end > start else { continue }
            let probabilities = Array(result.finalizedPredictions[index*count..<(index+1)*count])
            guard probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) })
            else { throw AppFailure.message("화자 분석 확률 오류") }
            let active = probabilities.filter { $0 >= 0.60 }.count
            let slot = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] })
            frames.append(SpeechDecision(speechProbability: probabilities.max() ?? 0,
                activeSpeakers: active, start: start, end: end,
                speakerSlot: active == 1 ? slot.map { speakerBase+$0 } : nil))
        }
        return frames
    }
}
#endif

#if canImport(DeepFilterNetCoreML)
import DeepFilterNetCoreML

actor DeepFilterEnhancement: EnhancementProvider {
    private var streamer: DeepFilterNetCoreMLStreamer?
    private var input: [Float] = []
    private var dry: [Float] = []
    private var mixing: [Float] = []
    func prepare() async throws { streamer = try await DeepFilterNetCoreMLStreamer.load(configuration: .init(variant: .deepFilterNet3)) }
    func process(_ mono: [Float], sampleRate: Double, wetMix: Float) async throws -> [Float] {
        guard sampleRate == 48000, let streamer else { throw AppFailure.message("DeepFilterNet 입력 형식 오류") }
        input += mono; dry += mono
        mixing += Array(repeating: wetMix, count: mono.count)
        var wet: [Float] = []
        while input.count >= streamer.hopSize {
            wet += try streamer.processHop(Array(input.prefix(streamer.hopSize)))
            input.removeFirst(streamer.hopSize)
        }
        return blend(wet)
    }
    func finish() async throws -> [Float] {
        guard let streamer else { return [] }
        var wet: [Float] = []
        if !input.isEmpty {
            let padding = streamer.hopSize-input.count
            wet += try streamer.processHop(input + Array(repeating: 0, count: padding))
            input = []
        }
        wet += try streamer.flush()
        let result = blend(Array(wet.prefix(dry.count)))
        streamer.reset()
        return result
    }
    func recoverUnprocessed() -> [Float] {
        let remaining = dry
        input = []; dry = []; mixing = []; streamer?.reset()
        return remaining
    }
    private func blend(_ wet: [Float]) -> [Float] {
        let count = min(wet.count, dry.count)
        let output = (0..<count).map { dry[$0]*(1-mixing[$0]) + wet[$0]*mixing[$0] }
        dry.removeFirst(count); mixing.removeFirst(count)
        return output
    }
}
#endif
