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

struct DeviceValidationErrorDetail: Codable, Sendable, Equatable {
    var domain: String
    var code: Int
    var localizedDescription: String
    var userInfo: [String: String]

    init(_ error: Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        localizedDescription = nsError.localizedDescription
        var values = [String: String]()
        for (key, value) in nsError.userInfo {
            values[String(describing: key)] = String(describing: value)
        }
        userInfo = values
    }
}

struct DeviceValidationScreenshotContinuity: Codable, Sendable {
    var attempted: Bool
    var succeeded: Bool
    var error: String?
    var errorDetail: DeviceValidationErrorDetail?
    var duration: Double?
    var mime: String?
    var width: Int?
    var height: Int?
    var sizeBytes: Int?

    var rawWindowCompleted: Bool
    var rawGapCount: Int
    var rawGapSeconds: Double
    var rawOverlapCount: Int
    var rawOverlapSeconds: Double

    var processedWindowCompleted: Bool
    var processedGapCount: Int
    var processedGapSeconds: Double
    var processedOverlapCount: Int
    var processedOverlapSeconds: Double

    var analyzerWindowCompleted: Bool
    var analyzerGapCount: Int
    var analyzerGapSeconds: Double
    var analyzerOverlapCount: Int
    var analyzerOverlapSeconds: Double

    var verdict: DeviceValidationVerdict
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
    var semanticSpeechResults: Int
    var invalidTimedSpeechResults: Int
    var captureRequestToFirstAudio: Double?
    var firstAudioToFirstSpeechResult: Double?
    var maxInputRMSDB: Double
    var maxInputPeakDB: Double
    var screenshotContinuity: DeviceValidationScreenshotContinuity
    var speechTrace: [SpeechResultTrace]
    var diarization: DiarizationDiagnostics
    var separatorModelBundled: Bool
    var diarizerModelBundled: Bool

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
            let explicitRestart = DeviceValidationInvariants.explicitStopRestart(
                firstStopped: pair[0].userStopped, secondStopped: pair[1].userStopped,
                firstEnd: pair[0].endedAt, secondStart: pair[1].startedAt)
            let clean = pair.allSatisfy {
                $0.rawChunks > 0 && $0.processedChunks > 0 && $0.analyzerChunks > 0 &&
                $0.sttPrepared && $0.speechAppendFrames > 0 && $0.semanticSpeechResults > 0 &&
                $0.invalidTimedSpeechResults == 0 && $0.errors.isEmpty && $0.verdict != .fail
            }
            let reset = pair.allSatisfy {
                abs($0.rawFirstTime ?? .infinity) <= startTolerance &&
                abs($0.processedFirstTime ?? .infinity) <= startTolerance &&
                abs($0.analyzerFirstTime ?? .infinity) <= max(startTolerance, Self.analyzerTimeTolerance($0))
            }
            let passed = explicitRestart && clean && reset
            restart = .init(name: "stop_restart", verdict: passed ? .pass : .fail,
                detail: passed
                    ? "두 세션 모두 사용자가 Stop했고, 시간순으로 새 캡처를 시작했으며 각 PCM 시간축이 0에서 재설정됐습니다."
                    : "수동 Stop 기록·세션 순서·PCM/STT 입력 상태·시간축 초기화 중 하나가 미충족입니다. 수동 Stop 후 재시작하세요.")
        }

        let overall: DeviceValidationVerdict
        if sessions.isEmpty { overall = .notTested }
        else if sessions.contains(where: { $0.verdict == .fail }) || restart.verdict == .fail { overall = .fail }
        else if sessions.contains(where: { $0.verdict == .warning }) || restart.verdict != .pass { overall = .warning }
        else { overall = .pass }

        return DeviceValidationReport(
            schemaVersion: 10,
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
enum ProductionOrchestrationContract {
    static func run() -> (Bool, String) {
        let capture = UUID()
        var original = Caption(captureID: capture, language: .japanese, source: "前重後。", start: 0, end: 4, isFinal: true)
        original.timedTextSpans = [
            .init(utf16Start: 0, utf16End: 1, start: 0, end: 1),
            .init(utf16Start: 1, utf16End: 2, start: 1, end: 2),
            .init(utf16Start: 2, utf16End: 4, start: 2, end: 4)
        ]
        let episode = OverlapEpisode(start: 1, end: 2)
        guard let target = LiveSeparationPass.target(for: original, episode: episode) else {
            return (false, "production target mapping rejected deterministic timed Primary row")
        }
        var a = Caption(captureID: capture, language: .japanese, source: "甲", start: 1.00, end: 1.70, isFinal: true)
        a.separationLane = 0
        a.timedTextSpans = [.init(utf16Start: 0, utf16End: 1, start: 1.00, end: 1.70)]
        var b = Caption(captureID: capture, language: .japanese, source: "乙", start: 1.20, end: 2.00, isFinal: true)
        b.separationLane = 1
        b.timedTextSpans = [.init(utf16Start: 0, utf16End: 1, start: 1.20, end: 2.00)]
        let frames = [
            [StemSpeechFrame(start: 1.00, end: 1.70, probability: 0.95)],
            [StemSpeechFrame(start: 1.20, end: 2.00, probability: 0.95)]
        ]
        do {
            let accepted = try SeparationAcceptance.accepted(.init(rows: [a,b], speechFrames: frames), target: target)
            var buffer = TranscriptBuffer(); buffer.begin(captureID: capture, language: .japanese); buffer.rows = [original]
            let ids = buffer.applySeparation(original: original, target: episode, separated: accepted)
            guard !ids.isEmpty, buffer.rows.count >= 3 else { return (false, "production applySeparation rejected accepted separator rows") }
            let groups = Set(buffer.rows.compactMap(\.semanticSentenceID))
            guard groups.count == 1 else { return (false, "semantic sentence identity was not preserved through production replacement") }
            return (true, "actual target → acceptance → TranscriptBuffer.applySeparation contract passed")
        } catch { return (false, error.localizedDescription) }
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

    private struct TimelineSnapshot {
        var gapCount: Int
        var gapSeconds: Double
        var overlapCount: Int
        var overlapSeconds: Double
        var lastEnd: Double?

        init(_ timeline: TimelineState) {
            gapCount = timeline.gapCount
            gapSeconds = timeline.gapSeconds
            overlapCount = timeline.overlapCount
            overlapSeconds = timeline.overlapSeconds
            lastEnd = timeline.lastEnd
        }
    }

    private struct ScreenshotStageWindow {
        var baseline: TimelineSnapshot
        var targetEnd: Double?
        var completed: TimelineSnapshot?

        init(timeline: TimelineState, postSeconds: Double) {
            baseline = TimelineSnapshot(timeline)
            targetEnd = timeline.lastEnd.map { $0 + postSeconds }
        }

        mutating func update(_ timeline: TimelineState) {
            guard completed == nil, let targetEnd, let lastEnd = timeline.lastEnd, lastEnd >= targetEnd else { return }
            completed = TimelineSnapshot(timeline)
        }

        func delta(using current: TimelineState) -> (completed: Bool, gapCount: Int, gapSeconds: Double, overlapCount: Int, overlapSeconds: Double) {
            let end = completed ?? TimelineSnapshot(current)
            return (
                completed != nil,
                max(0, end.gapCount - baseline.gapCount),
                max(0, end.gapSeconds - baseline.gapSeconds),
                max(0, end.overlapCount - baseline.overlapCount),
                max(0, end.overlapSeconds - baseline.overlapSeconds)
            )
        }
    }

    private struct ScreenshotProbeState {
        var startedUptime: Double
        var finishedUptime: Double?
        var succeeded = false
        var error: String?
        var errorDetail: DeviceValidationErrorDetail?
        var mime: String?
        var width: Int?
        var height: Int?
        var sizeBytes: Int?
        var raw: ScreenshotStageWindow
        var processed: ScreenshotStageWindow
        var analyzer: ScreenshotStageWindow
    }

    private let id = UUID()
    private let startedAt: Date
    private let startedUptime: Double
    private let requireScreenshotProbe: Bool
    private let requireTwoSpeakerProbe: Bool
    private var captureRequestedUptime: Double?
    private var screenshotProbe: ScreenshotProbeState?

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
    private var speechAudit = DeviceValidationSpeechAudit()
    private var speechResults: Int { speechAudit.callbackCount }
    private var finalSpeechResults: Int { speechAudit.finalCount }
    private var semanticSpeechResults: Int { speechAudit.recognizedCount }
    private var invalidTimedSpeechResults: Int { speechAudit.invalidTimedCount }
    private var invalidTimedExamples: [String] { speechAudit.invalidExamples }
    private var firstAudioUptime: Double?
    private var firstSpeechResultUptime: Double?
    private var maxInputRMSDB = -120.0
    private var maxInputPeakDB = -120.0
    private var speechTrace: [SpeechResultTrace] = []
    private var diarization = DiarizationDiagnostics(status: "화자 분석 준비 중")
    private var diarizationFirstStart: Double?
    private var diarizationLastEnd: Double?
    private var diarizationMaxGap: Double = 0
    private var stableSingleSpeakerSeconds: [String: Double] = [:]
    private var overlapProbeStart: Double?
    private var overlapProbeEnd: Double?
    private var overlapFramesInsideProbe = 0
    private var separatorModelBundled = false
    private var diarizerModelBundled = false

    private var pipelineWarnings = Set<String>()
    private var errors = [String]()

    init(startedAt: Date = Date(), startedUptime: Double = ProcessInfo.processInfo.systemUptime,
         requireScreenshotProbe: Bool = false, requireTwoSpeakerProbe: Bool = false) {
        self.startedAt = startedAt
        self.startedUptime = startedUptime
        self.requireScreenshotProbe = requireScreenshotProbe
        self.requireTwoSpeakerProbe = requireTwoSpeakerProbe
    }

    var currentSourceTime: Double? { rawTimeline.lastEnd }

    func markSTTPrepared() { sttPrepared = true }
    func markCaptureRequested(observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        if captureRequestedUptime == nil { captureRequestedUptime = observedAt }
    }

    func markScreenshotProbeStarted(observedAt: Double = ProcessInfo.processInfo.systemUptime,
                                    postWindowSeconds: Double = 5) {
        guard screenshotProbe == nil else { return }
        screenshotProbe = ScreenshotProbeState(
            startedUptime: observedAt,
            raw: ScreenshotStageWindow(timeline: rawTimeline, postSeconds: postWindowSeconds),
            processed: ScreenshotStageWindow(timeline: processedTimeline, postSeconds: postWindowSeconds),
            analyzer: ScreenshotStageWindow(timeline: analyzerTimeline, postSeconds: postWindowSeconds)
        )
    }

    func markScreenshotProbeFinished(metadata: [String: Any],
                                     observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        guard var probe = screenshotProbe else { return }
        probe.finishedUptime = observedAt
        probe.succeeded = true
        probe.mime = metadata["mime"] as? String
        probe.width = metadata["width"] as? Int
        probe.height = metadata["height"] as? Int
        probe.sizeBytes = metadata["size_bytes"] as? Int
        screenshotProbe = probe
    }

    func markScreenshotProbeFailed(
        _ error: Error,
        observedAt: Double = ProcessInfo.processInfo.systemUptime
    ) {
        guard var probe = screenshotProbe else { return }
        probe.finishedUptime = observedAt
        probe.succeeded = false
        probe.error = error.localizedDescription
        probe.errorDetail = DeviceValidationErrorDetail(error)
        screenshotProbe = probe
    }

    // Retained for deterministic metric-store tests that do not need an NSError.
    func markScreenshotProbeFailed(_ error: String,
                                   observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        guard var probe = screenshotProbe else { return }
        probe.finishedUptime = observedAt
        probe.succeeded = false
        probe.error = error
        screenshotProbe = probe
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
        if var probe = screenshotProbe {
            probe.raw.update(rawTimeline)
            screenshotProbe = probe
        }
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
        if var probe = screenshotProbe {
            probe.processed.update(processedTimeline)
            screenshotProbe = probe
        }
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
        if var probe = screenshotProbe {
            probe.analyzer.update(analyzerTimeline)
            screenshotProbe = probe
        }
    }

    func recordSpeechAppend(frames: Int) {
        guard frames > 0 else { return }
        speechAppendChunks += 1
        speechAppendFrames += Int64(frames)
    }

    func recordSpeechResult(text: String, final: Bool, start: Double, end: Double, finalizedThrough: Double?,
                            timedSpans: [TimedTextSpan] = [],
                            observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        speechAudit.record(text: text, final: final, timedSpans: timedSpans)
        if firstSpeechResultUptime == nil && DeviceValidationInvariants.hasRecognizedContent(text) {
            firstSpeechResultUptime = observedAt
        }
        speechTrace.append(.init(text: text, final: final, start: start, end: end,
                                 finalizedThrough: finalizedThrough, timedSpans: timedSpans))
        if speechTrace.count > 48 { speechTrace.removeFirst(speechTrace.count-48) }
    }

    // Deterministic metric-store tests that do not model recognizer text keep the
    // legacy counter-only seam. Production validation uses the full trace overload.
    func recordSpeechResult(final: Bool, observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        recordSpeechResult(text: "", final: final, start: 0, end: 0, finalizedThrough: nil, observedAt: observedAt)
    }

    func markOverlapProbe(start: Double) {
        guard start.isFinite, start >= 0 else { return }
        overlapProbeStart = start; overlapProbeEnd = nil; overlapFramesInsideProbe = 0
    }
    func endOverlapProbe(end: Double) {
        guard end.isFinite, let start = overlapProbeStart, end > start else { return }
        overlapProbeEnd = end
    }

    func recordDiarizationStatus(_ value: String) { diarization.status = value }

    func recordDiarization(_ decisions: [SpeechDecision]) {
        let valid = decisions.filter(\.isValid).sorted { $0.start < $1.start }
        guard !valid.isEmpty else { return }
        diarization.status = "화자 분석 동작 중"
        diarization.analysisActivatedAt = diarization.analysisActivatedAt ?? valid.first?.start
        diarization.updateCount += valid.count
        for frame in valid {
            if diarizationFirstStart == nil { diarizationFirstStart = frame.start }
            if let last = diarizationLastEnd, frame.start > last { diarizationMaxGap = max(diarizationMaxGap, frame.start-last) }
            diarizationLastEnd = max(diarizationLastEnd ?? frame.end, frame.end)
            if frame.speechProbability >= 0.60, frame.activeSpeakers == 1, let slot = frame.speakerSlot {
                diarization.singleSpeakerFrames += 1
                let key = "\(frame.identityEpoch):\(slot)"
                stableSingleSpeakerSeconds[key, default: 0] += frame.end-frame.start
            }
            if frame.speechProbability >= 0.60, frame.activeSpeakers >= 2 {
                diarization.overlapFrames += 1
                if let a = overlapProbeStart {
                    if let b = overlapProbeEnd {
                        if frame.end > a, frame.start < b { overlapFramesInsideProbe += 1 }
                    } else if frame.end > a {
                        // While the user is actively holding the probe open, every newly
                        // observed overlap frame is inside the expected window by definition.
                        overlapFramesInsideProbe += 1
                    }
                }
            }
        }
        var slots = Set(diarization.distinctSpeakerSlots)
        slots.formUnion(valid.compactMap {
            $0.speechProbability >= 0.60 && $0.activeSpeakers == 1 ? $0.speakerSlot : nil
        })
        diarization.distinctSpeakerSlots = slots.sorted()
        diarization.latestEnd = max(diarization.latestEnd ?? 0, valid.map(\.end).max() ?? 0)
        diarization.recentFrames += valid.map {
            DiarizationFrameTrace(speechProbability: $0.speechProbability, activeSpeakers: $0.activeSpeakers,
                                  start: $0.start, end: $0.end, speakerSlot: $0.speakerSlot,
                                  identityEpoch: $0.identityEpoch)
        }
        if diarization.recentFrames.count > 192 { diarization.recentFrames.removeFirst(diarization.recentFrames.count-192) }
    }

    func recordSeparatorModelBundled(_ value: Bool) { separatorModelBundled = value }
    func recordDiarizerModelBundled(_ value: Bool) { diarizerModelBundled = value }

    func recordPipelineMetrics(_ value: AudioMetrics) {
        if value.rmsDB.isFinite { maxInputRMSDB = max(maxInputRMSDB, value.rmsDB) }
        if value.peakDB.isFinite { maxInputPeakDB = max(maxInputPeakDB, value.peakDB) }
        for warning in value.warnings where !warning.isEmpty { pipelineWarnings.insert(warning) }
    }

    func recordError(_ value: String) {
        guard !value.isEmpty, !errors.contains(value) else { return }
        errors.append(value)
    }

    // Native stop errors are stored on AudioInput rather than thrown from stop().
    // Capture them before finish() so runtime_errors cannot report a false PASS.
    func recordNativeStopFailure(_ failure: String?) {
        guard let failure, !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        recordError("네이티브 종료 확인 실패: " + failure)
    }

    private func screenshotContinuityReport() -> DeviceValidationScreenshotContinuity {
        guard let probe = screenshotProbe else {
            return DeviceValidationScreenshotContinuity(
                attempted: false, succeeded: false,
                error: nil, errorDetail: nil, duration: nil, mime: nil, width: nil, height: nil, sizeBytes: nil,
                rawWindowCompleted: false, rawGapCount: 0, rawGapSeconds: 0, rawOverlapCount: 0, rawOverlapSeconds: 0,
                processedWindowCompleted: false, processedGapCount: 0, processedGapSeconds: 0, processedOverlapCount: 0, processedOverlapSeconds: 0,
                analyzerWindowCompleted: false, analyzerGapCount: 0, analyzerGapSeconds: 0, analyzerOverlapCount: 0, analyzerOverlapSeconds: 0,
                verdict: .notTested
            )
        }

        let raw = probe.raw.delta(using: rawTimeline)
        let processed = probe.processed.delta(using: processedTimeline)
        let analyzer = probe.analyzer.delta(using: analyzerTimeline)
        let completed = raw.completed && processed.completed && analyzer.completed
        let anomaly = raw.gapCount > 0 || raw.overlapCount > 0 ||
            processed.gapCount > 0 || processed.overlapCount > 0 ||
            analyzer.gapCount > 0 || analyzer.overlapCount > 0
        let verdict: DeviceValidationVerdict
        if !probe.succeeded { verdict = .fail }
        else if anomaly { verdict = .fail }
        else if !completed { verdict = .warning }
        else { verdict = .pass }

        return DeviceValidationScreenshotContinuity(
            attempted: true, succeeded: probe.succeeded,
            error: probe.error, errorDetail: probe.errorDetail,
            duration: probe.finishedUptime.map { max(0, $0 - probe.startedUptime) },
            mime: probe.mime, width: probe.width, height: probe.height, sizeBytes: probe.sizeBytes,
            rawWindowCompleted: raw.completed, rawGapCount: raw.gapCount, rawGapSeconds: raw.gapSeconds, rawOverlapCount: raw.overlapCount, rawOverlapSeconds: raw.overlapSeconds,
            processedWindowCompleted: processed.completed, processedGapCount: processed.gapCount, processedGapSeconds: processed.gapSeconds, processedOverlapCount: processed.overlapCount, processedOverlapSeconds: processed.overlapSeconds,
            analyzerWindowCompleted: analyzer.completed, analyzerGapCount: analyzer.gapCount, analyzerGapSeconds: analyzer.gapSeconds, analyzerOverlapCount: analyzer.overlapCount, analyzerOverlapSeconds: analyzer.overlapSeconds,
            verdict: verdict
        )
    }

    func finish(userStopped: Bool, endedAt: Date = Date(),
                endedUptime: Double = ProcessInfo.processInfo.systemUptime) -> DeviceValidationSessionReport {
        let rawFormatList = rawFormats.sorted(by: Self.formatSort)
        let processedFormatList = processedFormats.sorted(by: Self.formatSort)
        let analyzerFormatList = analyzerFormats.sorted(by: Self.formatSort)
        let screenshot = screenshotContinuityReport()
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

        if requireScreenshotProbe || screenshot.attempted {
            let verdict: DeviceValidationVerdict = screenshot.attempted ? screenshot.verdict : .warning
            let detail: String
            if !screenshot.attempted {
                detail = "스크린샷 캡처 검증이 실행되지 않았습니다. 실제 PCM이 5초 이상 흐른 뒤 자동 실행되도록 세션을 충분히 유지하세요."
            } else if !screenshot.succeeded {
                if let error = screenshot.errorDetail {
                    detail = "same-stream one-shot screen output FAIL [\(error.domain) \(error.code)] \(error.localizedDescription)"
                } else {
                    detail = "same-stream one-shot screen output FAIL · \(screenshot.error ?? "원인 미기록")"
                }
            } else {
                let duration = screenshot.duration.map { Self.seconds($0) } ?? "?"
                let size = [screenshot.width, screenshot.height].compactMap { $0 }.map(String.init).joined(separator: "×")
                detail = "capture \(duration) s · \(size.isEmpty ? "크기 미기록" : size) · raw gap/overlap \(screenshot.rawGapCount)/\(screenshot.rawOverlapCount) · processed \(screenshot.processedGapCount)/\(screenshot.processedOverlapCount) · analyzer \(screenshot.analyzerGapCount)/\(screenshot.analyzerOverlapCount) · post-window \(screenshot.rawWindowCompleted && screenshot.processedWindowCompleted && screenshot.analyzerWindowCompleted ? "complete" : "incomplete")"
            }
            checks.append(.init(name: "screenshot_audio_continuity", verdict: verdict, detail: detail))
        }

        checks.append(.init(name: "signal_detected",
            verdict: maxInputPeakDB > -70 ? .pass : .warning,
            detail: "max RMS \(String(format: "%.1f", maxInputRMSDB)) dBFS · max peak \(String(format: "%.1f", maxInputPeakDB)) dBFS"))

        checks.append(.init(name: "speech_results",
            verdict: semanticSpeechResults > 0 ? .pass : .warning,
            detail: semanticSpeechResults > 0
                ? "의미 있는 STT 원문 \(semanticSpeechResults)회 / 전체 callback \(speechResults)회 · final \(finalSpeechResults)회"
                : "STT callback \(speechResults)회 중 실제 인식된 텍스트가 없습니다. 실제 음성을 재생했는지 확인하세요."))

        // Whole-session counters are monotone. Only the exported raw transcript
        // remains a rolling 48-callback sample; discarded callbacks cannot erase FAIL.
        let timedIntegrity = speechAudit.timedIntegrityPassed
        let timedVerdict: DeviceValidationVerdict = semanticSpeechResults == 0 ? .warning : (timedIntegrity ? .pass : .fail)
        checks.append(.init(name: "speech_timed_span_integrity",
            verdict: timedVerdict,
            detail: "전체 semantic callback \(semanticSpeechResults)개 중 무효 \(invalidTimedSpeechResults)개. " +
                (timedIntegrity ? "UTF-16 coverage와 text/audio 시간 순서 통과."
                 : (semanticSpeechResults == 0 ? "텍스트가 없어 검증 불가."
                    : "무효 timed span 발견. " + invalidTimedExamples.joined(separator: " | ")))))

        if requireTwoSpeakerProbe {
            let coverageStart = diarizationFirstStart ?? .infinity
            let coverageEnd = diarizationLastEnd ?? 0
            let headLag = max(0, coverageStart - (processedTimeline.firstTime ?? 0))
            let coverageLag = max(0, processedTimeline.span - coverageEnd)
            let liveOK = diarization.updateCount > 0 && diarization.singleSpeakerFrames > 0 && headLag <= 0.35 && coverageLag <= 0.35 && diarizationMaxGap <= 0.35
            checks.append(.init(name: "live_diarization", verdict: liveOK ? .pass : .warning,
                detail: "frame \(diarization.updateCount) · head lag \(Self.ms(headLag)) ms · tail lag \(Self.ms(coverageLag)) ms · max gap \(Self.ms(diarizationMaxGap)) ms"))

            let stable = stableSingleSpeakerSeconds.filter { $0.value >= 0.50 }
            let epochs = Dictionary(grouping: stable.keys, by: { $0.split(separator: ":").first.map(String.init) ?? "" })
            let sameEpochPair = epochs.values.contains { $0.count >= 2 }
            checks.append(.init(name: "two_speaker_slots", verdict: sameEpochPair ? .pass : .warning,
                detail: sameEpochPair ? "같은 diarizer identity epoch 안에서 0.5초 이상 안정된 서로 다른 두 slot을 관측했습니다."
                    : "recovery epoch 변화는 두 화자로 세지 않습니다. 같은 epoch에서 안정된 두 단일화자 구간이 필요합니다. evidence: \(stable)"))

            let overlapWindowValid = overlapProbeStart != nil && overlapProbeEnd != nil
            checks.append(.init(name: "overlap_detected",
                verdict: overlapWindowValid && overlapFramesInsideProbe > 0 ? .pass : .warning,
                detail: overlapWindowValid ? "표시한 overlap probe window 내부 frame \(overlapFramesInsideProbe)개"
                    : "검증 중 '겹쳐 말하기 시작'과 '겹쳐 말하기 종료'를 눌러 expected overlap source-time window를 명시하세요."))

            checks.append(.init(name: "diarizer_model_bundled", verdict: diarizerModelBundled ? .pass : .fail,
                detail: diarizerModelBundled ? "LS-EEND 100ms 모델이 앱 번들에 포함되어 있습니다."
                                            : "필수 LS-EEND 모델이 앱 번들에 없습니다."))
            checks.append(.init(name: "separator_model_bundled", verdict: separatorModelBundled ? .pass : .fail,
                detail: separatorModelBundled ? "Separator.mlmodelc가 앱 번들에 포함되어 있습니다."
                                             : "필수 동시발화 Separator.mlmodelc가 앱 번들에 없습니다."))
        }

        let orchestration = ProductionOrchestrationContract.run()
        checks.append(.init(name: "production_orchestration_contract", verdict: orchestration.0 ? .pass : .fail, detail: orchestration.1))

        checks.append(.init(name: "pipeline_warnings",
            verdict: pipelineWarnings.isEmpty ? .pass : .warning,
            detail: pipelineWarnings.isEmpty ? "전처리 경고 없음" : pipelineWarnings.sorted().joined(separator: " | ")))

        let observedDuration = max(0, endedUptime - startedUptime)
        checks.append(.init(name: "observation_length",
            verdict: rawAudioDuration >= 10 ? .pass : .warning,
            detail: "세션 \(Self.seconds(observedDuration)) s · 실제 PCM \(Self.seconds(rawAudioDuration)) s · 20~30초 권장"))

        let verdict: DeviceValidationVerdict
        if checks.contains(where: { $0.verdict == .fail }) { verdict = .fail }
        else if checks.contains(where: { $0.verdict == .warning || $0.verdict == .notTested }) { verdict = .warning }
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
            finalSpeechResults: finalSpeechResults, semanticSpeechResults: semanticSpeechResults,
            invalidTimedSpeechResults: invalidTimedSpeechResults,
            captureRequestToFirstAudio: firstAudioLatency,
            firstAudioToFirstSpeechResult: speechLatency,
            maxInputRMSDB: maxInputRMSDB, maxInputPeakDB: maxInputPeakDB,
            screenshotContinuity: screenshot, speechTrace: speechTrace, diarization: diarization,
            separatorModelBundled: separatorModelBundled,
            diarizerModelBundled: diarizerModelBundled,
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
    private var activeMetrics: DeviceValidationMetricStore?

    var combinedReport: DeviceValidationReport { DeviceValidationReport.make(sessions: sessions) }

    func beginOverlapProbe() {
        guard let metrics = activeMetrics, let t = metrics.currentSourceTime else { return }
        metrics.markOverlapProbe(start: t)
        status = "겹쳐 말하기 구간 기록 중… 종료 버튼을 누를 때까지 두 사람이 동시에 말하세요."
    }

    func endOverlapProbe() {
        guard let metrics = activeMetrics, let t = metrics.currentSourceTime else { return }
        metrics.endOverlapProbe(end: t)
        status = "overlap probe 구간 기록 완료 · 계속 재생한 뒤 검증 정지하세요."
    }

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
        let metrics = DeviceValidationMetricStore(requireScreenshotProbe: true, requireTwoSpeakerProbe: true)
        activeMetrics = metrics
        let pipeline = AudioPreprocessor()
        let speech = AppleSpeechEngine()
        let input = SystemAudioInput()
        let liveAnalysisPreparation = OptionalProviderPreparation(serializeAnalysisPreparation: true)
        await liveAnalysisPreparation.startAvailable(analysis: true, enhancement: false)
        metrics.recordSeparatorModelBundled(Bundle.main.url(forResource: "Separator", withExtension: "mlmodelc", subdirectory: "Separation") != nil)
        if let resources = Bundle.main.resourceURL {
            var isDir: ObjCBool = false
            let lseend = resources.appendingPathComponent(
                "Diarization/LSEEND/ls_eend_dih3_100ms.mlmodelc", isDirectory: true)
            metrics.recordDiarizerModelBundled(
                FileManager.default.fileExists(atPath: lseend.path, isDirectory: &isDir) && isDir.boolValue)
        } else {
            metrics.recordDiarizerModelBundled(false)
        }
        var liveAnalysisConnected = false
        var failure: Error?
        var speechPrepared = false
        var rawAudioForScreenshot = 0.0
        var screenshotTriggered = false
        var screenshotTask: Task<Void, Never>?

        do {
            try Task.checkCancellation()
            try await speech.prepare(language: language, result: { text, final, start, end, finalizedThrough, timedSpans in
                metrics.recordSpeechResult(text: text, final: final, start: start, end: end,
                                           finalizedThrough: finalizedThrough, timedSpans: timedSpans)
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
            status = "대상 선택 후 두 사람이 번갈아 말하고, 중간 4~6초는 일부러 겹쳐 말하는 실제 음성을 20~30초 재생하세요."

            for try await chunk in sequence {
                try Task.checkCancellation()
                metrics.recordRaw(chunk)
                rawAudioForScreenshot += Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
                if !screenshotTriggered && rawAudioForScreenshot >= 5 {
                    screenshotTriggered = true
                    metrics.markScreenshotProbeStarted()
                    status = "PCM 수신 중 · 스크린샷/오디오 연속성 검증 중…"
                    screenshotTask = Task { @MainActor [weak self] in
                        do {
                            let metadata = try await input.captureLearningScreenshot()
                            metrics.markScreenshotProbeFinished(metadata: metadata)
                            if self?.running == true && self?.stopRequested == false {
                                self?.status = "PCM 수신 중 · same-stream 스크린샷 완료 · 5초 이상 더 재생하세요."
                            }
                        } catch {
                            metrics.markScreenshotProbeFailed(error)
                            if self?.running == true && self?.stopRequested == false {
                                self?.status = "PCM 수신 중 · same-stream 스크린샷 실패 · 계속 재생 후 JSON을 확인하세요."
                            }
                        }
                    }
                }
                if !liveAnalysisConnected {
                    let ready = await liveAnalysisPreparation.takeReady()
                    metrics.recordDiarizationStatus(ready.analysisStatus)
                    if let analysis = ready.analysis {
                        await pipeline.installPrepared(analysis: analysis, enhancement: nil)
                        liveAnalysisConnected = true
                        metrics.recordDiarizationStatus("화자 분석 연결됨 · 실시간 메타데이터")
                    }
                }
                let (processed, values) = try await pipeline.process(chunk)
                metrics.recordPipelineMetrics(values)
                metrics.recordDiarization(await pipeline.takeAnalysisUpdates())
                for output in processed {
                    metrics.recordProcessed(output)
                    try speech.append(output)
                    metrics.recordSpeechAppend(frames: Int(output.buffer.frameLength))
                }
                input.progress?.processed(chunk)
                if !processed.isEmpty && !screenshotTriggered { status = "PCM 수신 중 · 20~30초 권장" }
            }
        } catch {
            failure = error
            if !(error is CancellationError) { metrics.recordError(error.localizedDescription) }
        }

        if let screenshotTask { await screenshotTask.value }
        // A loader may become ready just after the final PCM. Like AppModel's
        // natural-EOF path, make one nonblocking mailbox handoff before closing it.
        // Explicit Stop/error must never await/attach optional analysis here.
        if failure == nil && !Task.isCancelled && !stopRequested && !liveAnalysisConnected {
            let finalReady = await liveAnalysisPreparation.takeReady()
            metrics.recordDiarizationStatus(finalReady.analysisStatus)
            if let analysis = finalReady.analysis {
                await pipeline.installPrepared(analysis: analysis, enhancement: nil)
                liveAnalysisConnected = true
                metrics.recordDiarizationStatus("화자 분석 연결됨 · EOF 백필")
            }
        }
        await liveAnalysisPreparation.cancel()
        await input.stop()
        // Stop may have been requested by the UI already; stop() coalesces
        // both callers, and stopFailure is only final after the shared stop.
        metrics.recordNativeStopFailure(input.stopFailure)
        self.input = nil

        if failure == nil {
            do {
                let tails = try await pipeline.finish(cancelAnalysis: false)
                metrics.recordDiarization(await pipeline.takeAnalysisUpdates())
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
        activeMetrics = nil
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
