import Foundation

struct PreparedOptionalProviders: Sendable {
    var analysis: (any SpeechAnalysisProvider)?
    var enhancement: (any EnhancementProvider)?
    var status: String
    var analysisStatus: String
    var enhancementStatus: String
}

// Only one live diarizer model preparation may own heavyweight FluidAudio setup at
// a time. A stopped capture closes delivery immediately, while a following capture
// waits asynchronously for the old loader to actually unwind instead of starting a
// second native/model loader in parallel. Primary STT never waits on this gate.
actor LiveAnalysisPreparationGate {
    static let shared = LiveAnalysisPreparationGate()
    private var owner: UUID?

    func acquire(_ id: UUID) async throws {
        while let owner, owner != id {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        owner = id
    }

    func release(_ id: UUID) {
        if owner == id { owner = nil }
    }
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
    private let serializeAnalysisPreparation: Bool

    init(serializeAnalysisPreparation: Bool = false) {
        self.serializeAnalysisPreparation = serializeAnalysisPreparation
    }

    func startAvailable(analysis wantsAnalysis: Bool = true, enhancement wantsEnhancement: Bool = true) {
        var analysis: AnalysisLoader?
        var enhancement: EnhancementLoader?
        #if PHASE2 && canImport(FluidAudio)
        if wantsAnalysis { analysis = { let value = FluidSpeechAnalysis(); try await value.prepare(); return value } }
        #endif
        #if PHASE2 && canImport(DeepFilterNetCoreML)
        if wantsEnhancement { enhancement = { let value = DeepFilterEnhancement(); try await value.prepare(); return value } }
        #endif
        start(analysis: analysis, enhancement: enhancement)
    }
    func start(analysis: AnalysisLoader?, enhancement: EnhancementLoader?) {
        guard !started && !closed else { return }
        started = true
        if let analysis {
            analysisStatus = "화자 분석 준비 대기 · 기본 STT 유지"
            let serialized = serializeAnalysisPreparation
            let lease = UUID()
            analysisTask = Task.detached(priority: .utility) { [weak self] in
                var acquired = false
                do {
                    if serialized {
                        try await LiveAnalysisPreparationGate.shared.acquire(lease)
                        acquired = true
                    }
                    await self?.analysisLoadingStarted()
                    try Task.checkCancellation()
                    let value = try await analysis()
                    try Task.checkCancellation()
                    await self?.receivedAnalysis(value)
                } catch {
                    if !Task.isCancelled { await self?.failedAnalysis() }
                }
                if acquired { await LiveAnalysisPreparationGate.shared.release(lease) }
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
    private func analysisLoadingStarted() {
        guard !closed else { return }
        analysisStatus = "화자 분석 준비 중 · 기본 STT 유지"
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
        let a = closed ? "입력 중지" : analysisStatus
        let e = closed ? "입력 중지" : enhancementStatus
        return PreparedOptionalProviders(analysis: readyAnalysis, enhancement: readyEnhancement,
            status: closed ? "입력 중지" : a + " · " + e,
            analysisStatus: a, enhancementStatus: e)
    }
    func cancel() {
        closed = true
        analysisTask?.cancel(); enhancementTask?.cancel()
        readyAnalysis = nil; readyEnhancement = nil
    }
    func waitUntilFinished() async {
        let analysis = analysisTask, enhancement = enhancementTask
        await analysis?.value; await enhancement?.value
        analysisTask = nil; enhancementTask = nil
    }
}

#if canImport(FluidAudio)
import FluidAudio
import CoreML

// Only explicitly prepared for separation; never loaded by the fast STT loop.
// VadManager.process resets its recurrent state per call at the pinned revision,
// so the second stem does not inherit the first stem's state.
actor FluidStemSpeechDetector: StemSpeechDetector {
    private let manager: VadManager
    static let bundledRelativeModelPath =
        "VAD/silero-vad-unified-256ms-v6.2.1.mlmodelc"

    static func bundledModelURL(bundle: Bundle = .main) throws -> URL {
        guard let resources = bundle.resourceURL else {
            throw AppFailure.message("VAD 앱 리소스 경로를 찾을 수 없습니다.")
        }
        let url = resources.appendingPathComponent(bundledRelativeModelPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppFailure.message("필수 Silero VAD 모델이 앱 번들에 없습니다.")
        }
        return url
    }

    init(bundle: Bundle = .main) throws {
        // Required separation acceptance must remain available offline. Never use
        // VadManager() here because that initializer may populate its model cache
        // from the network on a fresh install.
        let url = try Self.bundledModelURL(bundle: bundle)
        var configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: configuration)
        manager = VadManager(config: .default, vadModel: model)
    }
    func probabilities(_ samples: [Float]) async throws -> [Float] {
        try Task.checkCancellation()
        let results = try await manager.process(samples)
        try Task.checkCancellation()
        return results.map(\.probability)
    }
}

actor FluidSpeechAnalysis: SpeechAnalysisProvider {
    private var diarizer: LSEENDDiarizer?
    private var stabilizer: SpeakerActivityStabilizer?
    private var elapsed: Double = 0
    private var epoch: Double = 0
    private var speakerBase = 0
    private var identityEpoch = 0

    static let bundledRelativeModelPath =
        "Diarization/LSEEND/ls_eend_dih3_100ms.mlmodelc"

    static func bundledModelURL(bundle: Bundle = .main) throws -> URL {
        guard let resources = bundle.resourceURL else {
            throw AppFailure.message("화자 분석 앱 리소스 경로를 찾을 수 없습니다.")
        }
        let url = resources.appendingPathComponent(bundledRelativeModelPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppFailure.message("필수 LS-EEND 모델이 앱 번들에 없습니다.")
        }
        return url
    }

    func reset() {
        diarizer?.reset()
        stabilizer?.reset()
        elapsed = 0
        epoch = 0
        speakerBase += 10
        identityEpoch += 1
    }

    func prepare() async throws {
        // No runtime download/network fallback. Phase 2 must bundle the exact
        // pinned LS-EEND model and CI verifies the copied app resource before PASS.
        let modelURL = try Self.bundledModelURL()
        let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
        var config = DiarizerTimelineConfig.default(numSpeakers: 10, frameDurationSeconds: 0.1)
        config.maxStoredFrames = 200
        config.storeSegments = false
        let diarizer = LSEENDDiarizer(timelineConfig: config)
        try diarizer.initialize(model: model)
        self.diarizer = diarizer
        self.stabilizer = SpeakerActivityStabilizer(slotCount: model.metadata.maxSpeakers)
    }
    func process(_ mono: [Float], sampleRate: Double) async throws -> [SpeechDecision] {
        guard let diarizer, sampleRate > 0 else { return [] }
        var frames: [SpeechDecision] = []
        // Local identity only. Renew recurrent state before the upstream one-hour validation bound.
        if elapsed-epoch >= 45*60 {
            if let update = try diarizer.finalizeSession() { frames += try decisions(update.chunkResult) }
            diarizer.reset(); stabilizer?.reset(); epoch = elapsed; speakerBase += 10; identityEpoch += 1
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
            guard var stabilizer else {
                throw AppFailure.message("화자 분석 안정화기가 준비되지 않았습니다.")
            }
            let stable = stabilizer.classify(probabilities)
            self.stabilizer = stabilizer
            let slot = stable.detectedSpeakerCount == 1 ? stable.activeSlots.first : nil
            frames.append(SpeechDecision(speechProbability: stable.speechProbability,
                activeSpeakers: stable.detectedSpeakerCount, start: start, end: end,
                speakerSlot: slot.map { speakerBase+$0 }, identityEpoch: identityEpoch))
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
