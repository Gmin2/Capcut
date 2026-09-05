import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit

/// Crudest possible screen capture: one display, video only, fixed duration.
/// Writes raw frames straight to disk and does nothing else, because any work
/// done on the sample queue turns into dropped frames.
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private let queue = DispatchQueue(label: "com.mintu.cutaway.capture")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    private var sessionStarted = false
    private var frames = 0
    private var incomplete = 0
    private var notReady = 0
    private var firstPTS = CMTime.zero
    private var lastPTS = CMTime.zero
    private var events: EventRecorder?
    private var space: CaptureSpace?
    /// Only for the alignment check: burns the real cursor into the frames so
    /// logged positions can be compared against where it actually is.
    public var showCursorForVerification = false
    /// Off by default so a plain screen recording does not trip a camera prompt.
    public var captureWebcam = false
    private var webcam: WebcamRecorder?

    public override init() { super.init() }

    public func record(seconds: Double, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "cutaway", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no display"])
        }

        let scale = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2
        let w = Int(CGFloat(display.width) * scale)
        let h = Int(CGFloat(display.height) * scale)

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        self.writer = writer
        self.input = input

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showCursorForVerification
        config.queueDepth = 8

        let screenFrame = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.frame ?? CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        self.space = CaptureSpace(screenFrame: screenFrame, scale: scale)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream

        // Started before the screen stream so the camera is warm; the two are
        // aligned afterwards by comparing first-frame timestamps, not by
        // trying to start them simultaneously.
        if captureWebcam {
            if await WebcamRecorder.requestAccess() {
                let wc = WebcamRecorder()
                do {
                    try wc.start(to: url.deletingLastPathComponent()
                        .appendingPathComponent("webcam.mov"))
                    await wc.waitForFirstFrame()
                    webcam = wc
                } catch { Log.line("webcam unavailable: \(error.localizedDescription)") }
            } else {
                Log.line("webcam: camera permission denied")
            }
        }

        Log.line("recording \(w)x\(h) @60 for \(seconds)s -> \(url.lastPathComponent)")
        try await stream.startCapture()

        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        // Wall clock, not the last complete frame. ScreenCaptureKit stops
        // sending frames when nothing changes, so a take that ends on a still
        // screen would otherwise be silently truncated.
        let endPTS = CMClockGetTime(CMClockGetHostTimeClock())
        try await stream.stopCapture()
        input.markAsFinished()
        await writer.finishWriting()

        let dur0 = CMTimeGetSeconds(endPTS - firstPTS)
        let webcamTrack = await webcam?.stop()

        let manifest = Manifest(
            screen: Manifest.Track(file: url.lastPathComponent,
                                   pixelSize: [Double(w), Double(h)],
                                   offset: 0, duration: dur0, frames: frames),
            webcam: webcamTrack)
        try manifest.write(to: url.deletingLastPathComponent()
            .appendingPathComponent("recording.json"))

        try events?.stop(duration: dur0,
                         to: url.deletingLastPathComponent().appendingPathComponent("events.json"))

        let dur = dur0
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        Log.line("""
          wrote \(frames) frames in \(String(format: "%.2f", dur))s \
          (\(String(format: "%.1f", Double(frames) / max(dur, 0.001))) fps), \
          incomplete=\(incomplete) notReady=\(notReady), \
          \(String(format: "%.1f", Double(size) / 1_048_576)) MB
          """)
        Log.line("status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")")
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb) else { return }

        // SCStream sends idle/blank frames too; only .complete carries pixels.
        guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else {
            incomplete += 1
            return
        }

        guard let writer, let input else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

        if !sessionStarted {
            sessionStarted = true
            firstPTS = pts
            writer.startWriting()
            writer.startSession(atSourceTime: pts)

            // Ground truth for the clock-alignment risk: sample buffer PTS and
            // the host clock should read the same, which is what lets event
            // timestamps line up with video later.
            let host = CMClockGetTime(CMClockGetHostTimeClock())
            Log.line(String(format: "clock check  firstPTS=%.4f  hostClock=%.4f  delta=%.4f",
                            CMTimeGetSeconds(pts), CMTimeGetSeconds(host),
                            CMTimeGetSeconds(host) - CMTimeGetSeconds(pts)))

            // Anchored to the first frame's PTS, so event times are in the same
            // timeline as the video regardless of capture warmup.
            webcam?.setAnchor(pts)
            if let space {
                let er = EventRecorder(space: space)
                er.start(anchor: pts)
                events = er
            }
        }

        guard input.isReadyForMoreMediaData else { notReady += 1; return }
        input.append(sb)
        frames += 1
        lastPTS = pts
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.line("stream stopped with error: \(error)")
    }
}
