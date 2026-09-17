import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

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
    private struct ScreenshotTarget {
        let width: Int
        let height: Int
        let sourceWidth: Int
        let sourceHeight: Int

        var wasDownscaled: Bool { width < sourceWidth || height < sourceHeight }
    }

    func captureLearningScreenshot() async throws -> [String: Any] {
        guard active, let stream, let screenOutput, let contentFilter else {
            throw AppFailure.message("시스템 화면 캡처가 실행 중일 때만 스크린샷을 저장할 수 있습니다.")
        }
        let requestID = selectionID
        let target = try Self.screenshotTarget(for: contentFilter, maxEdge: 1600)
        let ticket = screenOutput.armScreenshot(minWidth: target.width, minHeight: target.height)
        let highResolution = Self.captureConfiguration(width: target.width, height: target.height)
        let lowResolution = Self.captureConfiguration(width: 16, height: 16)

        do {
            // iOS doesn't expose SCScreenshotManager. Reconfigure only the screen
            // dimensions of the already-authorized running stream, wait for one
            // matching .screen frame, then restore the 16×16 discard surface.
            // Audio capture remains enabled at the same 48 kHz stereo settings.
            try await stream.updateConfiguration(highResolution)
            let image = try await ticket.value()
            guard active, self.stream === stream, selectionID == requestID else {
                throw AppFailure.message("화면 공유 대상이 바뀌어 스크린샷을 취소했습니다.")
            }
            try await stream.updateConfiguration(lowResolution)
            return try Self.encodeScreenshot(image, target: target)
        } catch {
            screenOutput.cancelScreenshot(ticket, error: error)
            if active, self.stream === stream, selectionID == requestID {
                try? await stream.updateConfiguration(lowResolution)
            }
            throw error
        }
    }

    private static func screenshotTarget(for filter: SCContentFilter, maxEdge: Int) throws -> ScreenshotTarget {
        let scale = filter.pointPixelScale
        let rect = filter.contentRect
        guard scale.isFinite, scale > 0,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else {
            throw AppFailure.message("스크린샷 원본 화면 크기를 확인할 수 없습니다.")
        }
        let sourceWidth = max(1, Int((rect.width * scale).rounded()))
        let sourceHeight = max(1, Int((rect.height * scale).rounded()))
        let sourceEdge = max(sourceWidth, sourceHeight)
        let ratio = min(1, Double(maxEdge) / Double(sourceEdge))
        return ScreenshotTarget(
            width: max(1, Int((Double(sourceWidth) * ratio).rounded())),
            height: max(1, Int((Double(sourceHeight) * ratio).rounded())),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight)
    }

    private static func captureConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.width = width
        config.height = height
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
    private var screenOutput: ScreenFrameOutput?
    private var contentFilter: SCContentFilter?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    private var delegate: CaptureDelegate?
    private let picker = SCContentSharingPicker.shared
    private var active = false
    private var selectionID = UUID()

    func start() async throws -> AsyncThrowingStream<PCMChunk, Error> {
        // System audio is loss-intolerant: do not kill a long live session merely
        // because downstream work experiences a temporary burst. The live STT path
        // is now decoupled from diarization, so this queue should remain near-empty
        // in steady state; unbounded buffering is only a safety net for transient stalls.
        let (sequence, continuation) = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        active = true
        let delegate = CaptureDelegate(owner: self, continuation: continuation)
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
        let previous = stream
        let previousScreenOutput = screenOutput
        stream = nil; screenOutput = nil; contentFilter = nil
        previousScreenOutput?.cancelPending(AppFailure.message("화면 공유 대상이 변경되었습니다."))
        if let previous { try? await previous.stopCapture() }
        guard active, selectionID == requestID else { return }
        let config = Self.captureConfiguration(width: 16, height: 16)
        guard let delegate else { return }
        let screenOutput = ScreenFrameOutput()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        self.stream = stream
        self.screenOutput = screenOutput
        self.contentFilter = filter
        delegate.activate(stream)
        do {
            try stream.addStreamOutput(screenOutput, type: .screen, sampleHandlerQueue: screenOutput.queue)
            try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: delegate.queue)
            try await stream.startCapture()
            if !active || selectionID != requestID { try? await stream.stopCapture() }
        } catch {
            if self.stream === stream {
                self.stream = nil
                self.screenOutput = nil
                self.contentFilter = nil
            }
            screenOutput.cancelPending(error)
            if active && selectionID == requestID { continuation?.finish(throwing: error) }
        }
    }

    func stopped(_ stoppedStream: SCStream, error: Error) {
        if active && stream === stoppedStream {
            screenOutput?.cancelPending(error)
            contentFilter = nil
            continuation?.finish(throwing: error)
        }
    }

    func stop() async {
        active = false; selectionID = UUID()
        let previous = stream
        let previousScreenOutput = screenOutput
        stream = nil; screenOutput = nil; contentFilter = nil
        previousScreenOutput?.cancelPending(CancellationError())
        continuation?.finish(); continuation = nil
        if let delegate { picker.remove(delegate) }
        picker.isActive = false; delegate = nil
        if let previous { try? await previous.stopCapture() }
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
            queue.asyncAfter(deadline: .now() + 3) { [weak self, weak ticket] in
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
    private var origin: Double?
    private var clock = AudioSourceClock()
    private var streamID: ObjectIdentifier?
    init(owner: SystemAudioInput, continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation) {
        self.owner = owner; self.continuation = continuation
    }
    func activate(_ stream: SCStream) {
        // All SCStream callbacks use the capture clock. A new selected stream
        // must retain the original PTS origin, including the gap during selection.
        queue.sync { self.streamID = ObjectIdentifier(stream) }
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
        guard ObjectIdentifier(stream) == streamID, type == .audio, CMSampleBufferIsValid(sampleBuffer),
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
        switch continuation.yield(PCMChunk(buffer: buffer, time: time)) {
        case .terminated: return
        case .enqueued: break
        case .dropped:
            // .unbounded never drops under the current policy. Keep an explicit
            // failure if that policy changes in the future rather than losing PCM silently.
            continuation.finish(throwing: AppFailure.message("시스템 오디오 입력이 유실되었습니다."))
        @unknown default:
            continuation.finish(throwing: AppFailure.message("알 수 없는 시스템 오디오 입력 상태"))
        }
    }
}

#endif
