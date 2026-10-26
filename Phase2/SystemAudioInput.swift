import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// The picker may issue several selections while ScreenCaptureKit is suspending
// in startCapture/stopCapture. @MainActor isolation alone does not serialize
// those async operations: every await permits another selection to enter.
// Keep every transition in one FIFO, including transitions superseded by a
// later selection. A successor must never start before its predecessor ends.
@MainActor
final class CaptureSelectionQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let predecessor = tail
        tail = Task { @MainActor in
            await predecessor?.value
            await operation()
        }
    }

    func drain() async { await tail?.value }
}

// Two owners call SystemAudioInput.stop(): the user's Stop action and the
// input loop's deferred cleanup. All callers must await the SAME native-stop
// result, not let the second call see `stream == nil` and return early.
@MainActor
final class CaptureStopFlight {
    private var task: Task<Void, Never>?
    var hasStarted: Bool { task != nil }

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let task { await task.value; return }
        let created = Task { @MainActor in await operation() }
        task = created
        await created.value
    }
}

// Keep track of native stream stops whose completion has not been confirmed.
// In particular, a thrown stopCapture() may leave a running native stream.
// This ledger is process-wide, not owned by an individual capture instance.
@MainActor
final class CaptureNativeStopLedger {
    static let shared = CaptureNativeStopLedger()
    // Retain the object, not only ObjectIdentifier: reusing a deallocated
    // stream's identity must never accidentally clear a previous failure.
    // A failed native stop requires an app restart unless a later retry
    // explicitly confirms the old SCStream has stopped.
    private var unconfirmed: [ObjectIdentifier: AnyObject] = [:]

    var canStart: Bool { unconfirmed.isEmpty }
    func beganStopping(_ stream: AnyObject) { unconfirmed[ObjectIdentifier(stream)] = stream }
    func confirmedStopped(_ stream: AnyObject) { unconfirmed[ObjectIdentifier(stream)] = nil }
}

// Coalesce every stop of the same native stream (picker, user Stop,
// screenshot failure). A successful stop is idempotent even if a second
// caller arrives after completion. Failed stops remain retryable, but the
// ledger prevents a new capture while the native state is unconfirmed.
@MainActor
final class CaptureNativeStopFlights {
    private final class WeakReference {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }
    private struct Flight {
        let stream: AnyObject
        let task: Task<Void, Error>
    }
    private var running: [ObjectIdentifier: Flight] = [:]
    private var confirmed: [ObjectIdentifier: WeakReference] = [:]

    func stop(_ stream: AnyObject, operation: @escaping @MainActor () async throws -> Void) async throws {
        let id = ObjectIdentifier(stream)
        confirmed = confirmed.filter { $0.value.object != nil }
        if confirmed[id]?.object === stream { return }
        if let flight = running[id], flight.stream === stream {
            try await flight.task.value
            return
        }
        let work = Task { @MainActor in
            CaptureNativeStopLedger.shared.beganStopping(stream)
            try await operation()
            CaptureNativeStopLedger.shared.confirmedStopped(stream)
        }
        running[id] = Flight(stream: stream, task: work)
        do {
            try await work.value
            confirmed[id] = WeakReference(stream)
            running[id] = nil
        } catch {
            running[id] = nil
            throw error
        }
    }
}

#if targetEnvironment(simulator)

// ScreenCaptureKit is absent from the iOS 27 Simulator SDK. Keep the same
// AudioInput surface so the rest of the app and simulator-hosted core tests
// compile, but fail explicitly if system capture is actually requested.
// The physical-device branch below still imports and compiles the real
// ScreenCaptureKit implementation, so device validation cannot silently
// fall back to this path.
@MainActor
final class SystemAudioInput: NSObject, AudioInput {
    func captureLearningScreenshot() async throws -> [String: Any] {
        throw AppFailure.message("iOS Simulator에서는 화면 캡처를 사용할 수 없습니다.")
    }

    // Keep the simulator and physical-device signatures identical. This
    // overload is required by AppModel even though capture is unavailable.
    func captureLearningScreenshot(matchingSentenceStart start: Double, end: Double) async throws -> [String: Any] {
        throw AppFailure.message("iOS Simulator에서는 화면 캡처를 사용할 수 없습니다.")
    }

    func start() async throws -> AsyncThrowingStream<PCMChunk, Error> {
        throw AppFailure.message("iOS Simulator에서는 시스템 오디오 캡처를 사용할 수 없습니다.")
    }

    func stop() async {}
}

#else

@preconcurrency import ScreenCaptureKit

// Physical iOS 27+ implementation. This file is never included in the Playground target.
@MainActor
final class SystemAudioInput: NSObject, AudioInput {
    private let nativeStopFlights = CaptureNativeStopFlights()

    private func stopNativeCapture(_ source: SCStream) async throws {
        try await nativeStopFlights.stop(source) { try await source.stopCapture() }
    }

    private struct ScreenshotTarget {
        let width: Int
        let height: Int
        let sourceWidth: Int
        let sourceHeight: Int

        var wasDownscaled: Bool { width < sourceWidth || height < sourceHeight }
    }

    // Device Validation may probe screenshots without a caption. Saved study
    // screenshots always use the source-time-qualified overload below.
    func captureLearningScreenshot() async throws -> [String: Any] {
        try await captureLearningScreenshot(expectedSentence: nil)
    }

    func captureLearningScreenshot(matchingSentenceStart start: Double, end: Double) async throws -> [String: Any] {
        try await captureLearningScreenshot(expectedSentence: (start: start, end: end))
    }

    private func captureLearningScreenshot(expectedSentence: (start: Double, end: Double)?) async throws -> [String: Any] {
        guard active, let stream, let target = screenshotTarget else {
            throw AppFailure.message("시스템 화면 캡처가 실행 중일 때만 스크린샷을 저장할 수 있습니다.")
        }
        guard screenshotOutput == nil else {
            throw AppFailure.message("이미 저장용 스크린샷을 캡처하고 있습니다.")
        }
        // This comparison uses the first successfully delivered PCM from the
        // CURRENT selected stream, not the picker request UUID. A new picker
        // request has a different lifetime from its native audio source.
        if let expectedSentence {
            guard ScreenshotSourcePolicy.matches(sentenceStart: expectedSentence.start,
                    sentenceEnd: expectedSentence.end,
                    currentSourceFirstAudioTime: delegate?.firstAudioTime(for: stream)) else {
                throw AppFailure.message("자막과 현재 공유 대상이 달라 스크린샷을 생략합니다.")
            }
        }

        let requestID = selectionID
        let output = ScreenFrameOutput()
        let ticket = output.armScreenshot(minWidth: target.width, minHeight: target.height)
        screenshotOutput = output
        var attached = false
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            attached = true
            let image = try await ticket.value()
            guard active, selectionID == requestID,
                  self.stream === stream, self.screenshotOutput === output else {
                throw AppFailure.message("화면 공유 대상이 바뀌어 스크린샷을 취소했습니다.")
            }
            if let expectedSentence {
                guard ScreenshotSourcePolicy.matches(sentenceStart: expectedSentence.start,
                        sentenceEnd: expectedSentence.end,
                        currentSourceFirstAudioTime: delegate?.firstAudioTime(for: stream)) else {
                    throw AppFailure.message("화면 캡처 중 공유 대상이 달라졌습니다.")
                }
            }
            try stream.removeStreamOutput(output, type: .screen)
            attached = false
            if self.screenshotOutput === output { self.screenshotOutput = nil }
            return try Self.encodeScreenshot(image, target: target)
        } catch {
            let originalError = error
            output.cancelScreenshot(ticket, error: originalError)
            if attached {
                do {
                    // Exactly one cleanup site: a failed removal can be retried
                    // once here, without the old nested catch calling Stop twice.
                    try stream.removeStreamOutput(output, type: .screen)
                    attached = false
                } catch {
                    let detachError = error
                    // A screenshot output may remain attached, so fail closed.
                    // Concurrent user Stop joins this exact native operation.
                    var nativeStopConfirmed = false
                    do {
                        try await stopNativeCapture(stream)
                        nativeStopConfirmed = true
                    } catch {
                        // Keep `self.stream` for the later explicit Stop retry.
                        // The process-wide ledger blocks any fresh capture.
                    }
                    if self.stream === stream {
                        active = false
                        selectionID = UUID()
                        delegate?.deactivate()
                        if let delegate { picker.remove(delegate) }
                        picker.isActive = false
                        if nativeStopConfirmed { self.stream = nil }
                        self.contentFilter = nil
                        self.screenshotTarget = nil
                        continuation?.finish(throwing: detachError)
                    }
                }
            }
            if self.screenshotOutput === output { self.screenshotOutput = nil }
            throw originalError
        }
    }

    private static func screenshotTarget(for filter: SCContentFilter, maxEdge: Int) throws -> ScreenshotTarget {
        let scale = Double(filter.pointPixelScale)
        let rect = filter.contentRect
        let width = Double(rect.width)
        let height = Double(rect.height)
        guard scale.isFinite, scale > 0,
              width.isFinite, height.isFinite,
              width > 0, height > 0 else {
            throw AppFailure.message("스크린샷 원본 화면 크기를 확인할 수 없습니다.")
        }
        let sourceWidth = max(1, Int((width * scale).rounded()))
        let sourceHeight = max(1, Int((height * scale).rounded()))
        let sourceEdge = max(sourceWidth, sourceHeight)
        let ratio = min(1, Double(maxEdge) / Double(sourceEdge))
        return ScreenshotTarget(
            width: max(1, Int((Double(sourceWidth) * ratio).rounded())),
            height: max(1, Int((Double(sourceHeight) * ratio).rounded())),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight)
    }

    private static func audioCaptureConfiguration(screenTarget: ScreenshotTarget?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        // Define the one-frame screen-output dimensions up front. This does not
        // attach a .screen output:
        // during normal live STT the app receives only .audio samples. A .screen
        // destination is added temporarily only when captureLearningScreenshot()
        // is called, then removed immediately after one frame.
        if let screenTarget {
            config.width = screenTarget.width
            config.height = screenTarget.height
        } else {
            // Defensive fallback keeps audio capture available even if the picker
            // doesn't provide usable content dimensions. Screenshot saving will
            // remain unavailable for that selection.
            config.width = 16
            config.height = 16
        }
        return config
    }

    private static func encodeScreenshot(_ image: CGImage, target: ScreenshotTarget) throws -> [String: Any] {
        let scaled = downscale(image, maxEdge: 1600)
        let supported = CGImageDestinationCopyTypeIdentifiers() as NSArray
        let type: UTType = supported.contains(UTType.webP.identifier) ? .webP : .jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw AppFailure.message("저장용 스크린샷 인코더를 만들지 못했습니다.")
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        CGImageDestinationAddImage(destination, scaled, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw AppFailure.message("저장용 스크린샷 인코딩에 실패했습니다.")
        }
        let bytes = data as Data
        return [
            "base64": bytes.base64EncodedString(),
            "mime": type.preferredMIMEType ?? (type == .webP ? "image/webp" : "image/jpeg"),
            "width": scaled.width, "height": scaled.height, "size_bytes": bytes.count,
            "downscaled": target.wasDownscaled || scaled.width < image.width || scaled.height < image.height
        ]
    }

    private static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage {
        let edge = max(image.width, image.height)
        guard edge > maxEdge else { return image }
        let ratio = CGFloat(maxEdge) / CGFloat(edge)
        let size = CGSize(width: max(1, (CGFloat(image.width) * ratio).rounded()),
                          height: max(1, (CGFloat(image.height) * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage ?? image
    }

    private var stream: SCStream?
    private var contentFilter: SCContentFilter?
    private var screenshotTarget: ScreenshotTarget?
    private var screenshotOutput: ScreenFrameOutput?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    private var delegate: CaptureDelegate?
    private let picker = SCContentSharingPicker.shared
    private var active = false
    private var selectionID = UUID()
    private let selectionQueue = CaptureSelectionQueue()
    private let stopFlight = CaptureStopFlight()
    private(set) var progress: AudioInputProgress? = AudioInputProgress()
    private(set) var stopFailure: String?

    func start() async throws -> AsyncThrowingStream<PCMChunk, Error> {
        guard !stopFlight.hasStarted else {
            throw AppFailure.message("이미 종료 절차를 시작한 입력 인스턴스입니다. 새 입력을 생성하세요.")
        }
        guard CaptureNativeStopLedger.shared.canStart else {
            throw AppFailure.message("이전 시스템 캡처의 종료 여부가 확인되지 않았습니다. 앱을 완전히 종료한 뒤 다시 시작하세요.")
        }
        stopFailure = nil
        // An optional pass is shed well before this emergency bound. Never silently
        // drop live PCM or conceal unlimited latency/memory growth in an unbounded queue.
        let (sequence, continuation) = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let progress = AudioInputProgress()
        self.progress = progress
        self.continuation = continuation
        active = true
        let delegate = CaptureDelegate(owner: self, continuation: continuation, progress: progress)
        self.delegate = delegate
        var config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false
        config.showsCameraControl = false
        picker.defaultConfiguration = config
        picker.add(delegate); picker.isActive = true; picker.present()
        return sequence
    }

    func selected(_ filter: SCContentFilter) async {
        guard active else { return }
        let requestID = UUID(); selectionID = requestID

        let previousScreenshotOutput = screenshotOutput
        screenshotOutput = nil
        previousScreenshotOutput?.cancelPending(AppFailure.message("화면 공유 대상이 변경되었습니다."))

        // Enqueue rather than running a second stop/start concurrently with an
        // earlier picker callback. The request ID drops obsolete selections once
        // their predecessors finish; it does NOT skip their in-flight teardown.
        selectionQueue.enqueue { [weak self] in
            await self?.installSelected(filter, requestID: requestID)
        }
    }

    private func failSelection(_ underlying: Error) {
        guard active else { return }
        // Fail closed: a failed stop cannot establish that the old SCStream has
        // ended, so do not start a replacement or accept any more picker events.
        active = false
        selectionID = UUID()
        delegate?.deactivate()
        screenshotOutput?.cancelPending(underlying)
        screenshotOutput = nil
        if let delegate { picker.remove(delegate) }
        picker.isActive = false
        continuation?.finish(throwing: AppFailure.message(
            "이전 시스템 오디오 캡처 종료에 실패했습니다. 새 캡처를 시작하지 않았습니다: " + underlying.localizedDescription))
        continuation = nil
        // Retain the old stream for AppModel.run() -> stop() cleanup retry.
    }

    private func installSelected(_ filter: SCContentFilter, requestID: UUID) async {
        guard active, selectionID == requestID else { return }
        guard CaptureNativeStopLedger.shared.canStart else {
            failSelection(AppFailure.message("다른 시스템 캡처의 종료가 확인되지 않았습니다."))
            return
        }

        let previous = stream
        contentFilter = nil
        screenshotTarget = nil
        if let previous {
            delegate?.deactivate()
            do {
                try await stopNativeCapture(previous)
            } catch {
                failSelection(error)
                return
            }
            // A concurrent user Stop may invalidate this selection while the
            // old stream is stopping. It will wait for this handoff first.
            if self.stream === previous { self.stream = nil }
        }
        guard active, selectionID == requestID else { return }
        guard CaptureNativeStopLedger.shared.canStart else {
            failSelection(AppFailure.message("시스템 캡처 종료가 아직 확인되지 않았습니다."))
            return
        }

        let target = try? Self.screenshotTarget(for: filter, maxEdge: 1600)
        let config = Self.audioCaptureConfiguration(screenTarget: target)
        guard let delegate else { return }
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        self.stream = stream
        self.contentFilter = filter
        self.screenshotTarget = target
        delegate.activate(stream)
        var attemptedStart = false
        do {
            // Normal live operation is audio-only at the output boundary.
            // No .screen output is attached until an explicit save requests one frame.
            try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: delegate.queue)
            attemptedStart = true
            try await stream.startCapture()
            if !active || selectionID != requestID {
                // Superseded startCapture may finish after a newer picker request
                // (or Stop). Never silently abandon its live native stream.
                do {
                    try await stopNativeCapture(stream)
                    if self.stream === stream {
                        self.stream = nil
                        self.contentFilter = nil
                        self.screenshotTarget = nil
                    }
                } catch {
                    // Preserve the stream for the explicit Stop retry. When a
                    // newer selection exists, fail closed instead of letting it
                    // start while this stream's state is unknown.
                    failSelection(error)
                }
            }
        } catch {
            let startError = error
            // addStreamOutput may throw before we ever attempt to start. Once
            // startCapture was invoked, however, never assume a thrown start
            // proves that native resources were torn down. Confirm a stop or
            // preserve the stream in the unconfirmed-stop ledger.
            if attemptedStart {
                do {
                    try await stopNativeCapture(stream)
                    if self.stream === stream {
                        self.stream = nil
                        self.contentFilter = nil
                        self.screenshotTarget = nil
                    }
                } catch {
                    if active && selectionID == requestID { failSelection(error) }
                    // Preserve the stream for explicit Stop retry.
                    return
                }
            } else if self.stream === stream {
                self.stream = nil
                self.contentFilter = nil
                self.screenshotTarget = nil
            }
            if active && selectionID == requestID { continuation?.finish(throwing: startError) }
        }
    }

    func stopped(_ stoppedStream: SCStream, error: Error) {
        if active && stream === stoppedStream {
            screenshotOutput?.cancelPending(error)
            screenshotOutput = nil
            contentFilter = nil
            screenshotTarget = nil
            continuation?.finish(throwing: error)
        }
    }

    func stop() async {
        await stopFlight.run { [self] in await stopOnce() }
    }

    private func stopOnce() async {
        active = false; selectionID = UUID()

        let previousScreenshotOutput = screenshotOutput
        screenshotOutput = nil
        previousScreenshotOutput?.cancelPending(CancellationError())

        // Stop accepting PCM and unblock the input consumer *before* waiting
        // for an in-flight native selection transition. A native SDK call may
        // take an arbitrarily long time to respond.
        delegate?.deactivate()
        continuation?.finish(); continuation = nil

        // Finish any pending picker transition before examining `stream`.
        // Otherwise Stop can miss the old stream while a selection is awaiting
        // its stopCapture(), and incorrectly report a completed teardown.
        await selectionQueue.drain()
        let previous = stream
        stream = nil
        contentFilter = nil
        screenshotTarget = nil
        if let delegate { picker.remove(delegate) }
        picker.isActive = false
        delegate = nil
        if let previous {
            do {
                try await stopNativeCapture(previous)
            } catch {
                // The ledger deliberately keeps the unconfirmed SCStream. Do not
                // disguise a failed native teardown as the normal stopped state.
                stopFailure = "시스템 오디오 캡처 종료를 확인하지 못했습니다. 앱을 완전히 종료한 뒤 다시 시작하세요: "
                    + error.localizedDescription
            }
        }
    }
}

private final class ScreenshotFrameTicket: @unchecked Sendable {
    let minWidth: Int
    let minHeight: Int
    private let lock = NSLock()
    private var result: Result<CGImage, Error>?
    private var continuation: CheckedContinuation<CGImage, Error>?

    init(minWidth: Int, minHeight: Int) {
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    func value() async throws -> CGImage {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }, onCancel: {
            self.resolve(.failure(CancellationError()))
        })
    }

    func resolve(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class ScreenFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "JP-Live.capture.screen")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pending: ScreenshotFrameTicket?

    func armScreenshot(minWidth: Int, minHeight: Int) -> ScreenshotFrameTicket {
        let ticket = ScreenshotFrameTicket(minWidth: minWidth, minHeight: minHeight)
        queue.sync {
            pending?.resolve(.failure(AppFailure.message("새 스크린샷 요청으로 이전 요청을 취소했습니다.")))
            pending = ticket
            queue.asyncAfter(deadline: .now() + 5) { [weak self, weak ticket] in
                guard let self, let ticket, self.pending === ticket else { return }
                self.pending = nil
                ticket.resolve(.failure(AppFailure.message("고해상도 화면 프레임을 받지 못했습니다.")))
            }
        }
        return ticket
    }

    func cancelScreenshot(_ ticket: ScreenshotFrameTicket, error: Error) {
        let message = error.localizedDescription
        queue.async { [weak self, weak ticket] in
            guard let self, let ticket, self.pending === ticket else { return }
            self.pending = nil
            ticket.resolve(.failure(AppFailure.message(message)))
        }
    }

    func cancelPending(_ error: Error) {
        let message = error.localizedDescription
        queue.async { [weak self] in
            guard let self, let ticket = self.pending else { return }
            self.pending = nil
            ticket.resolve(.failure(AppFailure.message(message)))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let ticket = pending,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width >= ticket.minWidth, height >= ticket.minHeight else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else {
            pending = nil
            ticket.resolve(.failure(AppFailure.message("화면 프레임을 이미지로 변환하지 못했습니다.")))
            return
        }
        pending = nil
        ticket.resolve(.success(image))
    }
}

private final class CaptureDelegate: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    weak var owner: SystemAudioInput?
    let continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation
    let queue = DispatchQueue(label: "JP-Live.capture.audio")
    private let progress: AudioInputProgress
    private var origin: Double?
    private var clock = AudioSourceClock()
    private var streamID: ObjectIdentifier?
    // Written on the PCM callback queue; snapshot through queue.sync. The
    // capture-wide PTS origin is retained across stream selections.
    private var currentStreamFirstAudioTime: Double?
    private var failed = false
    init(owner: SystemAudioInput, continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation, progress: AudioInputProgress) {
        self.owner = owner; self.continuation = continuation; self.progress = progress
    }
    func activate(_ stream: SCStream) {
        // All SCStream callbacks use the capture clock. A new selected stream
        // must retain the original PTS origin, including the gap during selection.
        queue.sync {
            self.streamID = ObjectIdentifier(stream)
            self.currentStreamFirstAudioTime = nil
        }
    }
    func deactivate() {
        queue.sync {
            self.streamID = nil
            self.currentStreamFirstAudioTime = nil
        }
    }
    func firstAudioTime(for stream: SCStream) -> Double? {
        queue.sync {
            guard self.streamID == ObjectIdentifier(stream) else { return nil }
            return currentStreamFirstAudioTime
        }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in await owner?.selected(filter) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        if stream == nil { continuation.finish() }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) { continuation.finish(throwing: error) }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in owner?.stopped(stream, error: error) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !failed, ObjectIdentifier(stream) == streamID, type == .audio, CMSampleBufferIsValid(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            continuation.finish(throwing: AppFailure.message("시스템 PCM 복사 실패 (\(status))")); return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard pts.isFinite else {
            continuation.finish(throwing: AppFailure.message("시스템 오디오 PTS가 유효하지 않습니다.")); return
        }
        if origin == nil { origin = pts }
        let time = pts-origin!
        do { _ = try clock.accept(time: time, frames: buffer.frameLength, rate: format.sampleRate) }
        catch { continuation.finish(throwing: error); return }
        let chunk = PCMChunk(buffer: buffer, time: time)
        let pending = progress.captured(chunk)
        guard pending.pendingAudio <= 6 else {
            failed = true
            continuation.finish(throwing: AppFailure.message("빠른 STT 입력 처리가 6초 이상 지연되어 중지했습니다. 실시간 진단값을 확인하세요."))
            return
        }
        switch continuation.yield(chunk) {
        case .terminated: return
        case .enqueued:
            // Mark a source as available only after its PCM was enqueued.
            if currentStreamFirstAudioTime == nil { currentStreamFirstAudioTime = time }
        case .dropped:
            failed = true
            continuation.finish(throwing: AppFailure.message("시스템 오디오 대기열 한도를 초과해 입력을 중지했습니다."))
        @unknown default:
            continuation.finish(throwing: AppFailure.message("알 수 없는 시스템 오디오 입력 상태"))
        }
    }
}

#endif
