import Foundation
import AVFoundation

/// Records the camera alongside the screen. Runs as its own AVCaptureSession,
/// which is independent of SCStream, but both stamp sample buffers on the host
/// clock, so the two tracks share a timebase and only need an offset to align.
public final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.mintu.cutaway.webcam")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    private var anchor = CMTime.zero
    private var sessionStarted = false
    private var firstPTS = CMTime.zero
    private var lastPTS = CMTime.zero
    private(set) public var frames = 0
    private(set) public var size = CGSize.zero

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Set once the screen's first frame arrives; the camera is started before
    /// that so it has time to warm up, which on this Mac takes ~300ms.
    public func setAnchor(_ t: CMTime) { anchor = t }

    /// The camera takes ~1s to produce its first frame. Waiting for it before
    /// the screen stream starts means a talking-head opening actually has a
    /// picture from frame zero, instead of a blank first second.
    public func waitForFirstFrame(timeout: Double = 3.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !sessionStarted && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    public func start(to url: URL, preset: AVCaptureSession.Preset = .hd1920x1080) throws {

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "cutaway", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "no camera"])
        }
        session.beginConfiguration()
        session.sessionPreset = preset
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else {
            throw NSError(domain: "cutaway", code: 31)
        }
        session.addInput(deviceInput)

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        out.alwaysDiscardsLateVideoFrames = false
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw NSError(domain: "cutaway", code: 32) }
        session.addOutput(out)
        session.commitConfiguration()

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))

        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ])
        i.expectsMediaDataInRealTime = true
        w.add(i)
        writer = w
        input = i

        session.startRunning()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let writer, let input, CMSampleBufferIsValid(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

        if !sessionStarted {
            sessionStarted = true
            firstPTS = pts
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sb)
        frames += 1
        lastPTS = pts
    }

    /// Returns the track description, including how far after the screen's
    /// first frame the camera actually started.
    public func stop() async -> Manifest.Track? {
        session.stopRunning()
        guard let writer, let input, sessionStarted else { return nil }
        input.markAsFinished()
        await writer.finishWriting()

        let offset = CMTimeGetSeconds(firstPTS - anchor)
        let duration = CMTimeGetSeconds(lastPTS - firstPTS)
        Log.line(String(format: "webcam: %d frames %.0fx%.0f, offset %+.3fs, %.2fs, status=%d",
                        frames, size.width, size.height, offset, duration,
                        writer.status.rawValue))
        return Manifest.Track(file: writer.outputURL.lastPathComponent,
                              pixelSize: [size.width, size.height],
                              offset: offset, duration: duration, frames: frames)
    }
}
