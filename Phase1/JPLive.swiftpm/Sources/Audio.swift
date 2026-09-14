import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import CoreMedia

struct PCMChunk: @unchecked Sendable {
    // The producer transfers a newly allocated buffer; no subsequent mutation by producer.
    let buffer: AVAudioPCMBuffer
    let time: Double
    let decision: SpeechDecision?
    init(buffer: AVAudioPCMBuffer, time: Double, decision: SpeechDecision? = nil) {
        self.buffer = buffer; self.time = time; self.decision = decision
    }
}

@MainActor protocol AudioInput: AnyObject {
    func start() async throws -> AsyncThrowingStream<PCMChunk, Error>
    func stop() async
}

final class FileAudioInput: AudioInput {
    let url: URL
    private var task: Task<Void, Never>?
    init(url: URL) { self.url = url }
    func start() async throws -> AsyncThrowingStream<PCMChunk, Error> {
        guard task == nil else { throw AppFailure.message("이미 시작한 파일 입력입니다.") }
        let granted = url.startAccessingSecurityScopedResource()
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { if granted { url.stopAccessingSecurityScopedResource() }; throw error }
        let (stream, continuation) = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(30))
        let producer = Task.detached { [url] in
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do {
                let rate = file.processingFormat.sampleRate
                guard rate.isFinite, rate >= 10, rate <= 384000 else { throw AppFailure.message("파일 샘플레이트 오류") }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let position = file.framePosition
                    let frames = AVAudioFrameCount(min(Int64(rate / 10), file.length-position))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                        throw AppFailure.message("오디오 버퍼 생성 실패")
                    }
                    try file.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0, file.framePosition > position else {
                        throw AppFailure.message("파일 끝에 도달하기 전에 오디오 읽기가 멈췄습니다.")
                    }
                    switch continuation.yield(PCMChunk(buffer: buffer, time: Double(position)/rate)) {
                    case .dropped: throw AppFailure.message("오디오 처리 지연이 3초를 초과했습니다. 입력을 중지했습니다.")
                    case .terminated: return
                    case .enqueued: break
                    @unknown default: break
                    }
                    try await Task.sleep(for: .seconds(Double(buffer.frameLength)/rate))
                }
                continuation.finish()
            } catch is CancellationError { continuation.finish() }
            catch { continuation.finish(throwing: error) }
        }
        task = producer
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

struct AudioMetrics: Sendable {
    var time: Double = 0
    var rmsDB: Double = -120
    var peakDB: Double = -120
    var gainDB: Double = 0
    var speechProbability: Float? = nil
    var activeSpeakers: Int? = nil
    var speakerSlot: Int? = nil
    var warnings: [String] = []
}

// Per-stream state: never share this gain envelope between separated stems.
struct SpeechLeveler {
    var gain: Float = 1
    private var lastKnownSpeakerSlot: Int?
    mutating func process(_ input: [Float], speechProbability: Float?, allowUpwardGain: Bool = true,
                          speakerSlot: Int? = nil) -> [Float] {
        guard !input.isEmpty else { return input }
        // Overlap/unknown must not inherit a previous single-speaker gain ramp.
        // This is distinct from the still-unimplemented input calibration stage.
        if !allowUpwardGain { gain = 1 }
        // The caller supplies a slot only for a time-matched, finalized single
        // speaker interval. Unknown/low-confidence IDs neither reset nor replace
        // the last known identity. A confirmed new speaker starts a fresh envelope.
        if allowUpwardGain, let p = speechProbability, p >= 0.65, let speakerSlot {
            if let previous = lastKnownSpeakerSlot, previous != speakerSlot { gain = 1 }
            lastKnownSpeakerSlot = speakerSlot
        }
        let rms = sqrt(input.reduce(Float(0)) { $0 + $1*$1 } / Float(input.count))
        // No VAD => no upward AGC. Energy alone is not a speech detector.
        let target: Float
        if allowUpwardGain, let p = speechProbability, p >= 0.65, rms > 0.0001 {
            target = min(4, max(1, 0.10/rms))
        } else { target = 1 }
        let step = (target-gain) / Float(input.count)
        var output = [Float](); output.reserveCapacity(input.count)
        for x in input {
            gain += step
            let y = x * gain
            // Soft knee above -3 dBFS; hard ceiling is an emergency safety bound.
            let a = abs(y)
            let compressed = a > 0.707 ? 0.707 + (a-0.707)/4 : a
            output.append(max(-0.98, min(0.98, compressed * (y < 0 ? -1 : 1))))
        }
        return output
    }
}

struct StereoSelection {
    static func mono(left: [Float], right: [Float]) -> [Float] {
        guard left.count == right.count, !left.isEmpty else { return left }
        var ll: Float = 0, rr: Float = 0, lr: Float = 0
        for i in left.indices { ll += left[i]*left[i]; rr += right[i]*right[i]; lr += left[i]*right[i] }
        let correlation = lr / max(sqrt(ll*rr), 0.000001)
        // Avoid cancellation for near-antiphase channels. Original stereo remains in the ring.
        if correlation < -0.5 { return ll >= rr ? left : right }
        return zip(left, right).map { ($0+$1)*0.5 }
    }
}

@MainActor
final class AppleSpeechEngine {
    private var analyzer: SpeechAnalyzer?
    private var builder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: SpeechInputConverter?
    private var failed: String?
    private var inputObserver: ((AVAudioPCMBuffer, CMTime?) -> Void)?
    private var didStart = false
    func prepare(language: SourceLanguage, result: @escaping (String, Bool, Double, Double) -> Void,
                 failure: @escaping (String) -> Void,
                 inputObserver: ((AVAudioPCMBuffer, CMTime?) -> Void)? = nil) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue))
        else { throw AppFailure.message("이 기기에서 선택한 언어의 Apple STT를 지원하지 않습니다.") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        failed = nil
        self.inputObserver = inputObserver
        let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let installer = installation {
            try await installer.downloadAndInstall()
        }
        let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let available = bestFormat else {
            throw AppFailure.message("STT 입력 형식을 찾지 못했습니다.")
        }
        format = available
        converter = SpeechInputConverter(format: available)
        let analyzer = SpeechAnalyzer(modules: [transcriber]); self.analyzer = analyzer
        // Preprocessing now emits 10 ms frames. Allow the bounded 2 s analysis
        // release plus input backlog; 40 frames would reject even a healthy burst.
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(512))
        builder = continuation
        resultTask = Task {
            do {
                for try await r in transcriber.results {
                    result(String(r.text.characters), r.isFinal, r.range.start.seconds, CMTimeRangeGetEnd(r.range).seconds)
                }
            } catch {
                if !Task.isCancelled { self.failed = error.localizedDescription; failure(error.localizedDescription) }
            }
        }
        try await analyzer.start(inputSequence: sequence)
        didStart = true
    }
    func append(_ chunk: PCMChunk) throws {
        if let failed { throw AppFailure.message("STT 오류: " + failed) }
        guard let converter else { throw AppFailure.message("STT가 준비되지 않았습니다.") }
        for input in try converter.convert(chunk) { try yield(input) }
    }
    private func yield(_ input: AnalyzerInput) throws {
        guard input.buffer.frameLength > 0 else { return }
        guard let builder else { throw AppFailure.message("STT 입력 스트림이 없습니다.") }
        switch builder.yield(input) {
        case .dropped: throw AppFailure.message("STT 처리 지연으로 입력을 중지했습니다.")
        case .terminated: throw AppFailure.message("STT 입력 스트림이 종료되었습니다.")
        case .enqueued: inputObserver?(input.buffer, input.bufferStartTime)
        @unknown default: throw AppFailure.message("알 수 없는 STT 입력 상태")
        }
    }
    // Normal EOF and an explicit user stop drain accepted audio. On failure,
    // abort instead of feeding more input into a failed analyzer.
    func finish(aborting: Bool = false) async throws {
        var finishingError: Error?
        if !aborting, failed == nil, didStart {
            do { for input in try converter?.flush() ?? [] { try yield(input) } }
            catch { finishingError = error }
        }
        builder?.finish(); builder = nil
        if didStart && !aborting && failed == nil && finishingError == nil {
            do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
            catch { finishingError = error; await analyzer?.cancelAndFinishNow(); resultTask?.cancel() }
        } else {
            await analyzer?.cancelAndFinishNow(); resultTask?.cancel()
        }
        await resultTask?.value
        if let failed, finishingError == nil { finishingError = AppFailure.message("STT 오류: " + failed) }
        resultTask = nil; analyzer = nil; format = nil; converter = nil; inputObserver = nil; didStart = false; failed = nil
        if let finishingError { throw finishingError }
    }
}
