import Foundation
import Combine
@preconcurrency import AVFoundation
import CoreMedia
import UIKit

enum DeviceValidationVerdict: String, Codable, Sendable {
    case pass
    case warning
    case fail
    case notTested
}

struct DeviceValidationCheck: Codable, Identifiable, Sendable {
    var name: String
    var verdict: DeviceValidationVerdict
    var detail: String
    var id: String { name }
}

struct DeviceValidationAudioFormat: Codable, Hashable, Sendable {
    var sampleRate: Double
    var channels: Int
    var sampleFormat: String
    var interleaved: Bool

    init(sampleRate: Double, channels: Int, sampleFormat: String, interleaved: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleFormat = sampleFormat
        self.interleaved = interleaved
    }

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channels = Int(format.channelCount)
        interleaved = format.isInterleaved
        switch format.commonFormat {
        case .pcmFormatFloat32: sampleFormat = "float32"
        case .pcmFormatFloat64: sampleFormat = "float64"
        case .pcmFormatInt16: sampleFormat = "int16"
        case .pcmFormatInt32: sampleFormat = "int32"
        case .otherFormat: sampleFormat = "other"
        @unknown default: sampleFormat = "unknown"
        }
    }
}

struct DeviceValidationSessionReport: Codable, Identifiable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var userStopped: Bool

    var rawChunks: Int
    var rawFrames: Int64
    var rawFormats: [DeviceValidationAudioFormat]
    var rawAudioDuration: Double
    var rawTimelineSpan: Double
    var rawFirstTime: Double?
    var rawGapCount: Int
    var rawGapSeconds: Double
    var rawOverlapCount: Int
    var rawOverlapSeconds: Double

    var processedChunks: Int
    var processedFrames: Int64
    var processedFormats: [DeviceValidationAudioFormat]
    var processedAudioDuration: Double
    var processedTimelineSpan: Double
    var processedFirstTime: Double?
    var processedGapCount: Int
    var processedGapSeconds: Double
    var processedOverlapCount: Int
    var processedOverlapSeconds: Double

    var analyzerChunks: Int
    var analyzerFrames: Int64
    var analyzerFormats: [DeviceValidationAudioFormat]
    var analyzerAudioDuration: Double
    var analyzerTimelineSpan: Double
    var analyzerFirstTime: Double?
    var analyzerGapCount: Int
    var analyzerGapSeconds: Double
    var analyzerOverlapCount: Int
    var analyzerOverlapSeconds: Double

    var sttPrepared: Bool
    var speechAppendChunks: Int
    var speechAppendFrames: Int64
    var speechResults: Int
    var finalSpeechResults: Int
    var captureRequestToFirstAudio: Double?
    var firstAudioToFirstSpeechResult: Double?
    var maxInputRMSDB: Double
    var maxInputPeakDB: Double

    var pipelineWarnings: [String]
    var errors: [String]
    var checks: [DeviceValidationCheck]
    var verdict: DeviceValidationVerdict
}

struct DeviceValidationReport: Codable, Sendable {
    var schemaVersion: Int
    var createdAt: Date
    var appVersion: String
    var osVersion: String
    var deviceModel: String
    var sessions: [DeviceValidationSessionReport]
    var restartCheck: DeviceValidationCheck
    var overallVerdict: DeviceValidationVerdict

    @MainActor
    static func make(sessions: [DeviceValidationSessionReport]) -> DeviceValidationReport {
        let restart: DeviceValidationCheck
        if sessions.count < 2 {
            restart = .init(name: "stop_restart", verdict: .notTested,
                detail: "세션을 두 번 완료하면 stop → restart와 시간축 초기화를 검증합니다.")
        } else {
            let pair = Array(sessions.suffix(2))
            let startTolerance = 2.1 / 48000
            let clean = pair.allSatisfy {
                $0.rawChunks > 0 && $0.processedChunks > 0 && $0.analyzerChunks > 0 &&
                $0.errors.isEmpty && $0.verdict != .fail
            }
            let reset = pair.allSatisfy {
                abs($0.rawFirstTime ?? .infinity) <= startTolerance &&
                abs($0.processedFirstTime ?? .infinity) <= startTolerance &&
                abs($0.analyzerFirstTime ?? .infinity) <= max(startTolerance, Self.analyzerTimeTolerance($0))
            }
            restart = .init(name: "stop_restart", verdict: clean && reset ? .pass : .fail,
                detail: clean && reset
                    ? "연속 두 세션이 실제 PCM/STT 입력을 수신했고 각 세션 시간축이 0에서 새로 시작했습니다."
                    : "최근 두 세션 중 PCM/STT 입력, 종료 상태 또는 시간축 초기화가 올바르지 않습니다.")
        }

        let overall: DeviceValidationVerdict
        if sessions.isEmpty { overall = .notTested }
        else if sessions.contains(where: { $0.verdict == .fail }) || restart.verdict == .fail { overall = .fail }
        else if sessions.contains(where: { $0.verdict == .warning }) || restart.verdict != .pass { overall = .warning }
        else { overall = .pass }

        return DeviceValidationReport(
            schemaVersion: 2,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: UIDevice.current.model,
            sessions: sessions,
            restartCheck: restart,
            overallVerdict: overall
        )
    }

    private static func analyzerTimeTolerance(_ report: DeviceValidationSessionReport) -> Double {
        let rates = report.analyzerFormats.map(\.sampleRate).filter { $0 > 0 }
        return rates.min().map { 2.1 / $0 } ?? 2.1 / 48000
    }
}

@MainActor
final class DeviceValidationMetricStore {
    private struct TimelineState {
        var firstTime: Double?
        var lastEnd: Double?
        var gapCount = 0
        var gapSeconds: Double = 0
        var overlapCount = 0
        var overlapSeconds: Double = 0

        mutating func observe(time: Double, end: Double, rate: Double) -> String? {
            guard time.isFinite, end.isFinite, time >= 0, end > time, rate.isFinite, rate > 0 else {
                return "유효하지 않은 PCM timestamp"
            }
            if firstTime == nil { firstTime = time }
            if let lastEnd {
                let delta = time - lastEnd
                let tolerance = 1.5 / rate
                if delta > tolerance {
                    gapCount += 1
                    gapSeconds += delta
                } else if delta < -tolerance {
                    overlapCount += 1
                    overlapSeconds += -delta
                }
            }
            lastEnd = max(lastEnd ?? end, end)
            return nil
        }

        var span: Double { max(0, (lastEnd ?? 0) - (firstTime ?? 0)) }
    }

    private let id = UUID()
    private let startedAt: Date
    private let startedUptime: Double
    private var captureRequestedUptime: Double?

    private var rawChunkCount = 0
    private var rawFrames: Int64 = 0
    private var rawFormats = Set<DeviceValidationAudioFormat>()
    private var rawAudioDuration: Double = 0
    private var rawTimeline = TimelineState()

    private var processedChunkCount = 0
    private var processedFrames: Int64 = 0
    private var processedFormats = Set<DeviceValidationAudioFormat>()
    private var processedAudioDuration: Double = 0
    private var processedTimeline = TimelineState()

    private var analyzerChunkCount = 0
    private var analyzerFrames: Int64 = 0
    private var analyzerFormats = Set<DeviceValidationAudioFormat>()
    private var analyzerAudioDuration: Double = 0
    private var analyzerTimeline = TimelineState()

    private var sttPrepared = false
    private var speechAppendChunks = 0
    private var speechAppendFrames: Int64 = 0
    private var speechResults = 0
    private var finalSpeechResults = 0
    private var firstAudioUptime: Double?
    private var firstSpeechResultUptime: Double?
    private var maxInputRMSDB = -120.0
    private var maxInputPeakDB = -120.0

    private var pipelineWarnings = Set<String>()
    private var errors = [String]()

    init(startedAt: Date = Date(), startedUptime: Double = ProcessInfo.processInfo.systemUptime) {
        self.startedAt = startedAt
        self.startedUptime = startedUptime
    }

    func markSTTPrepared() { sttPrepared = true }
    func markCaptureRequested(observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        if captureRequestedUptime == nil { captureRequestedUptime = observedAt }
    }

    func recordRaw(_ chunk: PCMChunk, observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        recordRaw(time: chunk.time, frames: Int(chunk.buffer.frameLength),
                  format: DeviceValidationAudioFormat(chunk.buffer.format), observedAt: observedAt)
    }

    func recordRaw(time: Double, frames: Int, format: DeviceValidationAudioFormat, observedAt: Double) {
        guard frames > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
            recordError("유효하지 않은 raw PCM 형식/길이")
            return
        }
        if firstAudioUptime == nil { firstAudioUptime = observedAt }
        let duration = Double(frames) / format.sampleRate
        if let error = rawTimeline.observe(time: time, end: time + duration, rate: format.sampleRate) {
            recordError(error)
        }
        rawChunkCount += 1
        rawFrames += Int64(frames)
        rawAudioDuration += duration
        rawFormats.insert(format)
    }

    func recordProcessed(_ chunk: PCMChunk) {
        recordProcessed(time: chunk.time, frames: Int(chunk.buffer.frameLength),
                        format: DeviceValidationAudioFormat(chunk.buffer.format))
    }

    func recordProcessed(time: Double, frames: Int, format: DeviceValidationAudioFormat) {
        guard frames > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
            recordError("유효하지 않은 전처리 PCM 형식/길이")
            return
        }
        let duration = Double(frames) / format.sampleRate
        if let error = processedTimeline.observe(time: time, end: time + duration, rate: format.sampleRate) {
            recordError(error)
        }
        processedChunkCount += 1
        processedFrames += Int64(frames)
        processedAudioDuration += duration
        processedFormats.insert(format)
    }

    func recordAnalyzerInput(buffer: AVAudioPCMBuffer, startTime: CMTime?) {
        let frames = Int(buffer.frameLength)
        let format = DeviceValidationAudioFormat(buffer.format)
        guard frames > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
            recordError("유효하지 않은 SpeechAnalyzer PCM 형식/길이")
            return
        }
        let explicit = startTime.flatMap { value -> Double? in
            guard value.isValid, value.isNumeric, value.seconds.isFinite, value.seconds >= 0 else { return nil }
            return value.seconds
        }
        let start = explicit ?? analyzerTimeline.lastEnd ?? 0
        let duration = Double(frames) / format.sampleRate
        if let error = analyzerTimeline.observe(time: start, end: start + duration, rate: format.sampleRate) {
            recordError("SpeechAnalyzer: \(error)")
        }
        analyzerChunkCount += 1
        analyzerFrames += Int64(frames)
        analyzerAudioDuration += duration
        analyzerFormats.insert(format)
    }

    func recordSpeechAppend(frames: Int) {
        guard frames > 0 else { return }
        speechAppendChunks += 1
        speechAppendFrames += Int64(frames)
    }

    func recordSpeechResult(final: Bool, observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        if firstSpeechResultUptime == nil { firstSpeechResultUptime = observedAt }
        speechResults += 1
        if final { finalSpeechResults += 1 }
    }

    func recordPipelineMetrics(_ value: AudioMetrics) {
        if value.rmsDB.isFinite { maxInputRMSDB = max(maxInputRMSDB, value.rmsDB) }
        if value.peakDB.isFinite { maxInputPeakDB = max(maxInputPeakDB, value.peakDB) }
        for warning in value.warnings where !warning.isEmpty { pipelineWarnings.insert(warning) }
    }

    func recordError(_ value: String) {
        guard !value.isEmpty, !errors.contains(value) else { return }
        errors.append(value)
    }

    func finish(userStopped: Bool, endedAt: Date = Date(),
                endedUptime: Double = ProcessInfo.processInfo.systemUptime) -> DeviceValidationSessionReport {
        let rawFormatList = rawFormats.sorted(by: Self.formatSort)
        let processedFormatList = processedFormats.sorted(by: Self.formatSort)
        let analyzerFormatList = analyzerFormats.sorted(by: Self.formatSort)
        var checks = [DeviceValidationCheck]()

        checks.append(.init(name: "runtime_errors", verdict: errors.isEmpty ? .pass : .fail,
            detail: errors.isEmpty ? "캡처/전처리/STT 오류가 기록되지 않았습니다." : errors.joined(separator: " | ")))

        checks.append(.init(name: "raw_pcm_received",
            verdict: rawChunkCount > 0 ? .pass : .fail,
            detail: rawChunkCount > 0 ? "raw PCM \(rawChunkCount)개 · \(rawFrames) frames"
                                      : "실제 시스템 PCM을 한 번도 받지 못했습니다."))

        let rawFormatOK = !rawFormatList.isEmpty && rawFormatList.allSatisfy {
            abs($0.sampleRate - 48000) < 0.5 && $0.channels == 2
        }
        checks.append(.init(name: "raw_format_48k_stereo", verdict: rawFormatOK ? .pass : .fail,
            detail: rawFormatList.isEmpty ? "raw PCM 형식 없음"
                : rawFormatList.map(Self.formatDescription).joined(separator: ", ")))

        let sourceStartTolerance = 2.1 / 48000
        let rawStartOK = rawTimeline.firstTime.map { abs($0) <= sourceStartTolerance } ?? false
        checks.append(.init(name: "raw_session_origin", verdict: rawStartOK ? .pass : .fail,
            detail: rawTimeline.firstTime.map { "first \(Self.ms($0)) ms" } ?? "raw 시작 시각 없음"))

        let rawContinuityOK = rawTimeline.gapCount == 0 && rawTimeline.overlapCount == 0
        checks.append(.init(name: "raw_timeline_continuity", verdict: rawContinuityOK ? .pass : .fail,
            detail: "gap \(rawTimeline.gapCount)회/\(Self.ms(rawTimeline.gapSeconds)) ms · overlap \(rawTimeline.overlapCount)회/\(Self.ms(rawTimeline.overlapSeconds)) ms"))

        let processedFormatOK = !processedFormatList.isEmpty && processedFormatList.allSatisfy {
            abs($0.sampleRate - 48000) < 0.5 && $0.channels == 1 && $0.sampleFormat == "float32"
        }
        checks.append(.init(name: "processed_format_48k_mono_float32", verdict: processedFormatOK ? .pass : .fail,
            detail: processedFormatList.isEmpty ? "전처리 PCM 형식 없음"
                : processedFormatList.map(Self.formatDescription).joined(separator: ", ")))

        let processedStartDelta = abs((processedTimeline.firstTime ?? .infinity) - (rawTimeline.firstTime ?? 0))
        checks.append(.init(name: "processed_session_origin",
            verdict: processedStartDelta <= sourceStartTolerance ? .pass : .fail,
            detail: "raw 대비 시작 Δ \(Self.ms(processedStartDelta)) ms"))

        let gapDurationDelta = abs(processedTimeline.gapSeconds - rawTimeline.gapSeconds)
        let processedContinuityOK = processedTimeline.gapCount == rawTimeline.gapCount &&
            processedTimeline.overlapCount == 0 && gapDurationDelta <= sourceStartTolerance
        checks.append(.init(name: "processed_timeline_continuity",
            verdict: processedContinuityOK ? .pass : .fail,
            detail: "gap \(processedTimeline.gapCount)회/\(Self.ms(processedTimeline.gapSeconds)) ms · overlap \(processedTimeline.overlapCount)회/\(Self.ms(processedTimeline.overlapSeconds)) ms · source-gap Δ \(Self.ms(gapDurationDelta)) ms"))

        let durationDelta = abs(rawAudioDuration - processedAudioDuration)
        let durationOK = rawChunkCount > 0 && processedChunkCount > 0 && durationDelta <= sourceStartTolerance
        checks.append(.init(name: "pcm_duration_preserved", verdict: durationOK ? .pass : .fail,
            detail: "raw \(Self.seconds(rawAudioDuration)) s · processed \(Self.seconds(processedAudioDuration)) s · Δ \(Self.ms(durationDelta)) ms"))

        checks.append(.init(name: "speech_analyzer_input_received",
            verdict: analyzerChunkCount > 0 ? .pass : .fail,
            detail: analyzerChunkCount > 0 ? "AnalyzerInput \(analyzerChunkCount)개 · \(analyzerFrames) frames"
                                         : "SpeechAnalyzer에 실제 입력 버퍼가 전달되지 않았습니다."))

        let analyzerFormatOK = analyzerFormatList.count == 1 && analyzerFormatList.allSatisfy {
            $0.channels == 1 && $0.sampleRate.isFinite && $0.sampleRate > 0
        }
        checks.append(.init(name: "speech_analyzer_format_stable", verdict: analyzerFormatOK ? .pass : .fail,
            detail: analyzerFormatList.isEmpty ? "AnalyzerInput 형식 없음"
                : analyzerFormatList.map(Self.formatDescription).joined(separator: ", ")))

        let analyzerRate = analyzerFormatList.map(\.sampleRate).filter { $0 > 0 }.min() ?? 48000
        let analyzerTolerance = max(sourceStartTolerance, 2.1 / analyzerRate)
        let analyzerStartDelta = abs((analyzerTimeline.firstTime ?? .infinity) - (processedTimeline.firstTime ?? 0))
        checks.append(.init(name: "speech_analyzer_session_origin",
            verdict: analyzerStartDelta <= analyzerTolerance ? .pass : .fail,
            detail: "processed 대비 시작 Δ \(Self.ms(analyzerStartDelta)) ms"))

        let analyzerContinuityOK = analyzerTimeline.gapCount == processedTimeline.gapCount &&
            analyzerTimeline.overlapCount == 0 &&
            abs(analyzerTimeline.gapSeconds - processedTimeline.gapSeconds) <= analyzerTolerance
        checks.append(.init(name: "speech_analyzer_timeline_continuity",
            verdict: analyzerContinuityOK ? .pass : .fail,
            detail: "gap \(analyzerTimeline.gapCount)회/\(Self.ms(analyzerTimeline.gapSeconds)) ms · overlap \(analyzerTimeline.overlapCount)회/\(Self.ms(analyzerTimeline.overlapSeconds)) ms"))

        let analyzerDurationDelta = abs(processedAudioDuration - analyzerAudioDuration)
        let analyzerDurationOK = processedChunkCount > 0 && analyzerChunkCount > 0 && analyzerDurationDelta <= analyzerTolerance
        checks.append(.init(name: "speech_analyzer_duration_preserved",
            verdict: analyzerDurationOK ? .pass : .fail,
            detail: "processed \(Self.seconds(processedAudioDuration)) s · analyzer \(Self.seconds(analyzerAudioDuration)) s · Δ \(Self.ms(analyzerDurationDelta)) ms"))

        let appendAccountingOK = sttPrepared && processedFrames > 0 &&
            speechAppendFrames == processedFrames && speechAppendChunks == processedChunkCount
        checks.append(.init(name: "speech_append_accounting", verdict: appendAccountingOK ? .pass : .fail,
            detail: "prepared \(sttPrepared) · append \(speechAppendChunks) chunks/\(speechAppendFrames) frames · processed \(processedChunkCount) chunks/\(processedFrames) frames"))

        checks.append(.init(name: "signal_detected",
            verdict: maxInputPeakDB > -70 ? .pass : .warning,
            detail: "max RMS \(String(format: "%.1f", maxInputRMSDB)) dBFS · max peak \(String(format: "%.1f", maxInputPeakDB)) dBFS"))

        checks.append(.init(name: "speech_results",
            verdict: speechResults > 0 ? .pass : .warning,
            detail: speechResults > 0 ? "result \(speechResults)회 · final \(finalSpeechResults)회"
                                      : "STT 입력은 전달됐지만 결과 텍스트가 없습니다. 실제 음성을 재생했는지 확인하세요."))

        checks.append(.init(name: "pipeline_warnings",
            verdict: pipelineWarnings.isEmpty ? .pass : .warning,
            detail: pipelineWarnings.isEmpty ? "전처리 경고 없음" : pipelineWarnings.sorted().joined(separator: " | ")))

        let observedDuration = max(0, endedUptime - startedUptime)
        checks.append(.init(name: "observation_length",
            verdict: rawAudioDuration >= 10 ? .pass : .warning,
            detail: "세션 \(Self.seconds(observedDuration)) s · 실제 PCM \(Self.seconds(rawAudioDuration)) s · 20~30초 권장"))

        let verdict: DeviceValidationVerdict
        if checks.contains(where: { $0.verdict == .fail }) { verdict = .fail }
        else if checks.contains(where: { $0.verdict == .warning }) { verdict = .warning }
        else { verdict = .pass }

        let firstAudioLatency: Double? = {
            guard let captureRequestedUptime, let firstAudioUptime else { return nil }
            return max(0, firstAudioUptime - captureRequestedUptime)
        }()
        let speechLatency: Double? = {
            guard let firstAudioUptime, let firstSpeechResultUptime else { return nil }
            return max(0, firstSpeechResultUptime - firstAudioUptime)
        }()

        return DeviceValidationSessionReport(
            id: id, startedAt: startedAt, endedAt: endedAt, userStopped: userStopped,
            rawChunks: rawChunkCount, rawFrames: rawFrames, rawFormats: rawFormatList,
            rawAudioDuration: rawAudioDuration, rawTimelineSpan: rawTimeline.span, rawFirstTime: rawTimeline.firstTime,
            rawGapCount: rawTimeline.gapCount, rawGapSeconds: rawTimeline.gapSeconds,
            rawOverlapCount: rawTimeline.overlapCount, rawOverlapSeconds: rawTimeline.overlapSeconds,
            processedChunks: processedChunkCount, processedFrames: processedFrames,
            processedFormats: processedFormatList, processedAudioDuration: processedAudioDuration,
            processedTimelineSpan: processedTimeline.span, processedFirstTime: processedTimeline.firstTime,
            processedGapCount: processedTimeline.gapCount, processedGapSeconds: processedTimeline.gapSeconds,
            processedOverlapCount: processedTimeline.overlapCount, processedOverlapSeconds: processedTimeline.overlapSeconds,
            analyzerChunks: analyzerChunkCount, analyzerFrames: analyzerFrames, analyzerFormats: analyzerFormatList,
            analyzerAudioDuration: analyzerAudioDuration, analyzerTimelineSpan: analyzerTimeline.span,
            analyzerFirstTime: analyzerTimeline.firstTime, analyzerGapCount: analyzerTimeline.gapCount,
            analyzerGapSeconds: analyzerTimeline.gapSeconds, analyzerOverlapCount: analyzerTimeline.overlapCount,
            analyzerOverlapSeconds: analyzerTimeline.overlapSeconds,
            sttPrepared: sttPrepared, speechAppendChunks: speechAppendChunks,
            speechAppendFrames: speechAppendFrames, speechResults: speechResults,
            finalSpeechResults: finalSpeechResults,
            captureRequestToFirstAudio: firstAudioLatency,
            firstAudioToFirstSpeechResult: speechLatency,
            maxInputRMSDB: maxInputRMSDB, maxInputPeakDB: maxInputPeakDB,
            pipelineWarnings: pipelineWarnings.sorted(), errors: errors,
            checks: checks, verdict: verdict
        )
    }

    private static func formatSort(_ a: DeviceValidationAudioFormat, _ b: DeviceValidationAudioFormat) -> Bool {
        if a.sampleRate != b.sampleRate { return a.sampleRate < b.sampleRate }
        if a.channels != b.channels { return a.channels < b.channels }
        if a.sampleFormat != b.sampleFormat { return a.sampleFormat < b.sampleFormat }
        return !a.interleaved && b.interleaved
    }

    private static func formatDescription(_ value: DeviceValidationAudioFormat) -> String {
        "\(Int(value.sampleRate.rounded())) Hz/\(value.channels)ch/\(value.sampleFormat)/\(value.interleaved ? "interleaved" : "planar")"
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func ms(_ value: Double) -> String {
        value.isFinite ? String(format: "%.3f", value * 1000) : "∞"
    }
}

@MainActor
final class DeviceValidationController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "검증 세션을 시작하세요."
    @Published private(set) var sessions: [DeviceValidationSessionReport] = []
    @Published private(set) var reportURL: URL?
    @Published private(set) var exportError = ""

    private var input: SystemAudioInput?
    private var runTask: Task<Void, Never>?
    private var stopRequested = false

    var combinedReport: DeviceValidationReport { DeviceValidationReport.make(sessions: sessions) }

    func start(language: SourceLanguage) {
        guard !running else { return }
        running = true
        stopRequested = false
        exportError = ""
        status = "Apple STT 준비 중…"
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(language: language)
        }
    }

    func stop() async {
        guard running else { return }
        stopRequested = true
        status = "입력 정리 중…"
        if let input { await input.stop() }
        else { runTask?.cancel() }
    }

    func reset() {
        guard !running else { return }
        sessions = []
        reportURL = nil
        exportError = ""
        status = "검증 세션을 시작하세요."
    }

    private func run(language: SourceLanguage) async {
        let metrics = DeviceValidationMetricStore()
        let pipeline = AudioPreprocessor()
        let speech = AppleSpeechEngine()
        let input = SystemAudioInput()
        var failure: Error?
        var speechPrepared = false

        do {
            try Task.checkCancellation()
            try await speech.prepare(language: language, result: { _, final, _, _ in
                metrics.recordSpeechResult(final: final)
            }, failure: { message in
                metrics.recordError("STT 비동기 오류: \(message)")
            }, inputObserver: { buffer, startTime in
                metrics.recordAnalyzerInput(buffer: buffer, startTime: startTime)
            })
            speechPrepared = true
            metrics.markSTTPrepared()
            try Task.checkCancellation()

            status = "공유 대상을 선택하세요."
            metrics.markCaptureRequested()
            let sequence = try await input.start()
            self.input = input
            status = "대상 선택 후 실제 음성을 20~30초 재생하세요."

            for try await chunk in sequence {
                try Task.checkCancellation()
                metrics.recordRaw(chunk)
                let (processed, values) = try await pipeline.process(chunk)
                metrics.recordPipelineMetrics(values)
                for output in processed {
                    metrics.recordProcessed(output)
                    try speech.append(output)
                    metrics.recordSpeechAppend(frames: Int(output.buffer.frameLength))
                }
                if !processed.isEmpty { status = "PCM 수신 중 · 20~30초 권장" }
            }
        } catch {
            failure = error
            if !(error is CancellationError) { metrics.recordError(error.localizedDescription) }
        }

        await input.stop()
        self.input = nil

        if failure == nil {
            do {
                let tails = try await pipeline.finish(cancelAnalysis: false)
                for output in tails {
                    metrics.recordProcessed(output)
                    try speech.append(output)
                    metrics.recordSpeechAppend(frames: Int(output.buffer.frameLength))
                }
                if speechPrepared { try await speech.finish() }
            } catch {
                metrics.recordError("종료 처리 오류: \(error.localizedDescription)")
                await pipeline.cancel()
                if speechPrepared { try? await speech.finish(aborting: true) }
            }
        } else {
            await pipeline.cancel()
            if speechPrepared { try? await speech.finish(aborting: true) }
        }

        let report = metrics.finish(userStopped: stopRequested)
        sessions.append(report)
        refreshExport()
        running = false
        runTask = nil

        switch report.verdict {
        case .pass:
            status = sessions.count >= 2 ? "세션 통과 · 재시작 검증 결과를 확인하세요." : "세션 통과 · 한 번 더 실행하면 재시작도 검증합니다."
        case .warning:
            status = "세션 완료 · 경고 항목을 확인하세요."
        case .fail:
            status = "세션 실패 · JSON 보고서를 공유하세요."
        case .notTested:
            status = "검증되지 않음"
        }
    }

    private func refreshExport() {
        do {
            let report = DeviceValidationReport.make(sessions: sessions)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("JP-Live-DeviceValidation", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: report.createdAt)
                .replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("JP-Live-device-validation-\(stamp).json")
            try data.write(to: url, options: .atomic)
            reportURL = url
            exportError = ""
        } catch {
            reportURL = nil
            exportError = error.localizedDescription
        }
    }
}
