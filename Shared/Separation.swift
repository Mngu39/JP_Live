import Foundation
import CoreML
import AVFoundation

struct SeparatedAudio: Sendable {
    var start: Double
    var sampleRate: Double
    var stems: [[Float]]
}

// Explicit model contract produced by Tools/export_separator.py. No weights are fabricated.
actor TwoSpeakerSeparator {
    private var model: MLModel?
    private let rate: Double = 16000
    private let window = 64000
    func prepare(modelURL: URL) throws {
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        guard model.modelDescription.inputDescriptionsByName["mixture"]?.multiArrayConstraint?.shape == [1, 64000],
              model.modelDescription.outputDescriptionsByName["stems"] != nil else {
            throw AppFailure.message("2화자 분리 모델 형식이 일치하지 않습니다.")
        }
        self.model = model
    }
    func separate(_ samples: [Float], start: Double) throws -> SeparatedAudio {
        guard let model, samples.count == window else { throw AppFailure.message("16kHz 4초 분리 입력과 준비된 모델이 필요합니다.") }
        let input = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
        for i in samples.indices { input[i] = NSNumber(value: samples[i]) }
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mixture": MLFeatureValue(multiArray: input)]))
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
        guard activeSpeakers == 2, let probability, probability >= 0.65 else { consecutive = 0; return false }
        consecutive += 1
        return consecutive >= 3
    }
}

@MainActor
final class SeparatedSpeechExperiment {
    // Standalone verification path, deliberately not enabled in the live transcript until
    // conversion, duplicate suppression and real-device latency have passed the acceptance tests.
    func transcribe(_ audio: SeparatedAudio, language: SourceLanguage) async throws -> [Caption] {
        guard audio.stems.count == 2 else { throw AppFailure.message("두 stem만 지원합니다.") }
        let captureID = UUID()
        let first = AppleSpeechEngine(), second = AppleSpeechEngine()
        var rows: [Caption] = []
        var failures: [String] = []
        let engines = [first, second]
        do {
            for speaker in 0..<2 {
                try await engines[speaker].prepare(language: language, result: { text, final, start, end in
                    guard final else { return }
                    rows.append(Caption(captureID: captureID, language: language, source: text,
                        tokens: LocalTokenizer.tokens(text, language: language), start: audio.start+start,
                        end: audio.start+end, isFinal: true, speaker: speaker))
                }, failure: { failures.append($0) })
            }
            for speaker in 0..<2 {
                var leveler = SpeechLeveler()
                // TODO before live integration: run a speech detector on each stem,
                // align its probabilities to short audio frames, and retain one gain
                // envelope per stem. nil currently provides limiting only; it does
                // NOT satisfy independent quiet-speaker leveling. Never fake VAD=1.
                let samples = leveler.process(audio.stems[speaker], speechProbability: nil)
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false)!
                // Feed short buffers to avoid assuming an unbounded recognizer input size.
                var cursor = 0
                while cursor < samples.count {
                    let n = min(Int(audio.sampleRate/10), samples.count-cursor)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                    buffer.frameLength = AVAudioFrameCount(n)
                    for i in 0..<n { buffer.floatChannelData![0][i] = samples[cursor+i] }
                    try engines[speaker].append(PCMChunk(buffer: buffer, time: Double(cursor)/audio.sampleRate))
                    cursor += n
                }
            }
            async let a: Void = first.finish()
            async let b: Void = second.finish()
            _ = try await (a, b)
            if !failures.isEmpty { throw AppFailure.message(failures.joined(separator: " · ")) }
        } catch {
            let originalError = error
            var cleanupFailures: [String] = []
            for engine in engines {
                do { try await engine.finish() }
                catch { cleanupFailures.append(error.localizedDescription) }
            }
            if !cleanupFailures.isEmpty {
                throw AppFailure.message(([originalError.localizedDescription] + cleanupFailures).joined(separator: " · "))
            }
            throw originalError
        }
        return rows.sorted { $0.start < $1.start }
    }
}
