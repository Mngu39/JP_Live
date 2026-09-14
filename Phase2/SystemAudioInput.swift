import Foundation
@preconcurrency import AVFoundation
import CoreMedia

#if targetEnvironment(simulator)

// ScreenCaptureKit is absent from the iOS 27 Simulator SDK. Keep the same
// AudioInput surface so the rest of the app and simulator-hosted core tests
// compile, but fail explicitly if system capture is actually requested.
// The physical-device branch below still imports and compiles the real
// ScreenCaptureKit implementation, so device validation cannot silently
// fall back to this path.
@MainActor
final class SystemAudioInput: NSObject, AudioInput {
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
    private var stream: SCStream?
    private var screenOutput: ScreenDiscardOutput?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    private var delegate: CaptureDelegate?
    private let picker = SCContentSharingPicker.shared
    private var active = false
    private var selectionID = UUID()
    func start() async throws -> AsyncThrowingStream<PCMChunk, Error> {
        let (sequence, continuation) = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(150))
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
        stream = nil; screenOutput = nil
        if let previous { try? await previous.stopCapture() }
        _ = previousScreenOutput
        guard active, selectionID == requestID else { return }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Screen pixels are not a product input. Keep the required screen output
        // surface tiny, omit cursor composition, and discard its callbacks on an
        // independent queue so screen delivery cannot serialize ahead of audio.
        config.width = 16; config.height = 16
        config.showsCursor = false
        guard let delegate else { return }
        let screenOutput = ScreenDiscardOutput()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        self.stream = stream
        self.screenOutput = screenOutput
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
            }
            if active && selectionID == requestID { continuation?.finish(throwing: error) }
        }
    }
    func stopped(_ stoppedStream: SCStream, error: Error) {
        if active && stream === stoppedStream { continuation?.finish(throwing: error) }
    }
    func stop() async {
        active = false; selectionID = UUID()
        let previous = stream
        let previousScreenOutput = screenOutput
        stream = nil; screenOutput = nil
        continuation?.finish(); continuation = nil
        if let delegate { picker.remove(delegate) }
        picker.isActive = false; delegate = nil
        if let previous { try? await previous.stopCapture() }
        _ = previousScreenOutput
    }
}

private final class ScreenDiscardOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "JP-Live.capture.screen")

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Deliberately empty. The screen output exists only to preserve the
        // ScreenCaptureKit capture lifecycle; no pixel, timing, or app state is consumed.
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
        if case .dropped = continuation.yield(PCMChunk(buffer: buffer, time: time)) {
            continuation.finish(throwing: AppFailure.message("시스템 오디오 처리 큐가 가득 찼습니다."))
        }
    }
}

#endif
