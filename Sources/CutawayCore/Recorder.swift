import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit

/// Screen capture with pause. Writes raw frames straight to disk and does
/// nothing else, because any work done on the sample queue turns into dropped
/// frames.
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private let queue = DispatchQueue(label: "com.mintu.cutaway.capture")
    public let clock = RecordClock()

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var url: URL?

    private var sessionStarted = false
    private var frames = 0
    private var incomplete = 0
    private var droppedWhilePaused = 0
    private var firstPTS = CMTime.zero
    private var lastPTS = CMTime.zero
    private var size = CGSize.zero

    private var events: EventRecorder?
    private var webcam: WebcamRecorder?
    public var webcamSession: AVCaptureSession? { webcam?.captureSession }
    private var micWriter: AudioWriter?
    private var systemWriter: AudioWriter?

    public var showCursorForVerification = false
    public var captureWebcam = false
    public var captureMicrophone = false
    public var captureSystemAudio = false
    /// Keystroke overlay. Needs Input Monitoring, so it stays off by default.
    public var captureKeys = false

    /// Bundle ids whose windows are kept out of the capture entirely. Better
    /// than masking afterwards: the pixels never exist, so there is nothing to
    /// leak if the raw file is shared.
    public var excludeApps: [String] = []
    /// Capture just this app's windows instead of the whole display.
    public var onlyApp: String?
    /// Which display to record. nil means the one with the menu bar, which is
    /// what a person means by "my screen" when they have two.
    public var displayID: CGDirectDisplayID?
    /// Part of the display to record, in display points with the origin top
    /// left. Nil records all of it.
    public var area: CGRect?
    /// AVCaptureDevice uniqueID. Nil uses the system default camera.
    public var cameraID: String?

    public private(set) var isRecording = false
    public var isPaused: Bool { clock.isPaused }
    /// Recorded seconds so far, paused time excluded.
    public var elapsed: Double { sessionStarted ? clock.elapsed() : 0 }
    public var onStateChange: (() -> Void)?

    public override init() { super.init() }

    // MARK: transport

    public func start(to url: URL) async throws {
        guard !isRecording else { return }
        self.url = url

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = Recorder.pickDisplay(content, id: displayID) else {
            throw NSError(domain: "cutaway", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        if content.displays.count > 1 {
            Log.line("recording display \(display.displayID) of \(content.displays.count)")
        }

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
        let scale = screen?.backingScaleFactor ?? 2
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let crop = area.map { $0.integral.intersection(bounds) }.flatMap { $0.width >= 64 && $0.height >= 64 ? $0 : nil }
        let region = crop ?? bounds
        // hevc wants even dimensions
        let w = Int(region.width * scale) & ~1
        let h = Int(region.height * scale) & ~1
        size = CGSize(width: w, height: h)

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        if let crop {
            config.sourceRect = crop
            Log.line("recording area \(Int(crop.width))x\(Int(crop.height)) at \(Int(crop.minX)),\(Int(crop.minY))")
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showCursorForVerification
        config.queueDepth = 8
        config.capturesAudio = captureSystemAudio
        config.captureMicrophone = captureMicrophone

        let filter = Recorder.makeFilter(display: display, content: content,
                                         excludeApps: excludeApps, onlyApp: onlyApp)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureSystemAudio {
            systemWriter = AudioWriter(url: dir.appendingPathComponent("system.m4a"))
            try stream.addStreamOutput(self, type: .audio,
                                       sampleHandlerQueue: DispatchQueue(label: "cutaway.sysaudio"))
        }
        if captureMicrophone {
            micWriter = AudioWriter(url: dir.appendingPathComponent("mic.m4a"))
            try stream.addStreamOutput(self, type: .microphone,
                                       sampleHandlerQueue: DispatchQueue(label: "cutaway.mic"))
        }
        self.stream = stream

        if captureWebcam {
            if await WebcamRecorder.requestAccess() {
                let wc = WebcamRecorder(clock: clock)
                do {
                    try wc.start(to: dir.appendingPathComponent("webcam.mov"), deviceID: cameraID)
                    // Wait for the first camera frame so a talking-head opening
                    // actually has a picture from frame zero.
                    await wc.waitForFirstFrame()
                    webcam = wc
                } catch { Log.line("webcam unavailable: \(error.localizedDescription)") }
            } else {
                Log.line("webcam: camera permission denied")
            }
        }

        // events are mapped into the recorded region, so a cropped take still
        // gets its cursor and clicks in the right place
        let screenFrame = screen?.frame ?? bounds
        let space = CaptureSpace(screenFrame: CGRect(x: screenFrame.minX + region.minX,
                                                     y: screenFrame.maxY - region.maxY,
                                                     width: region.width, height: region.height),
                                 scale: scale)
        let er = EventRecorder(space: space, clock: clock)
        er.captureKeys = captureKeys
        if captureKeys, !EventRecorder.canCaptureKeys {
            EventRecorder.requestKeyAccess()
            Log.line("keycast: grant Input Monitoring in System Settings, "
                     + "then relaunch Cutaway. Recording without keystrokes.")
        }
        events = er

        isRecording = true
        Log.line("recording \(w)x\(h) @60 -> \(url.lastPathComponent)")
        try await stream.startCapture()
        onStateChange?()
    }

    public func pause() {
        guard isRecording, !clock.isPaused else { return }
        clock.pause()
        Log.line(String(format: "paused at %.2fs", elapsed))
        onStateChange?()
    }

    public func resume() {
        guard isRecording, clock.isPaused else { return }
        clock.resume()
        Log.line(String(format: "resumed (%.2fs paused in total)", clock.pausedSeconds))
        onStateChange?()
    }

    @discardableResult
    public func stop() async throws -> Manifest? {
        guard isRecording, let stream, let writer, let input, let url else { return nil }
        if clock.isPaused { clock.resume() }
        isRecording = false

        let endPTS = clock.adjusted(RecordClock.now())
        do {
            try await stream.stopCapture()
        } catch {
            Log.line("capture did not stop cleanly: \(error.localizedDescription)")
        }
        input.markAsFinished()
        await writer.finishWriting()

        let duration = CMTimeGetSeconds(endPTS - firstPTS)
        let webcamTrack = await webcam?.stop()
        let micTrack = await micWriter?.finish(anchor: firstPTS)
        let sysTrack = await systemWriter?.finish(anchor: firstPTS)

        let dir = url.deletingLastPathComponent()
        let manifest = Manifest(
            screen: Manifest.Track(file: url.lastPathComponent,
                                   pixelSize: [size.width, size.height],
                                   offset: 0, duration: duration, frames: frames),
            webcam: webcamTrack, mic: micTrack, systemAudio: sysTrack)
        try manifest.write(to: dir.appendingPathComponent("recording.json"))
        try events?.stop(duration: duration,
                         to: dir.appendingPathComponent("events.json"))

        Log.line(String(format: """
          wrote %d frames in %.2fs (%.1f fps), incomplete=%d, paused=%.2fs, \
          dropped-while-paused=%d, %.1f MB
          """, frames, duration, Double(frames) / max(duration, 0.001),
          incomplete, clock.pausedSeconds, droppedWhilePaused,
          Double(((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0)
            / 1_048_576))

        if let m = micTrack, m.duration > 0.5 {
            do {
                let t = try await Transcriber.run(
                    audio: dir.appendingPathComponent(m.file), offset: m.offset)
                try t.write(to: dir)
            } catch { Log.line("transcript skipped: \(error.localizedDescription)") }
        }

        self.stream = nil
        onStateChange?()
        return manifest
    }

    // MARK: capture

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        // Paused: drop everything. Timestamps of later samples get the paused
        // span subtracted, so the file ends up continuous.
        if clock.isPaused {
            if type == .screen { droppedWhilePaused += 1 }
            return
        }

        switch type {
        case .audio:
            if let r = Recorder.retime(sb, minus: clock.pausedOffset) { systemWriter?.append(r) }
            return
        case .microphone:
            if let r = Recorder.retime(sb, minus: clock.pausedOffset) { micWriter?.append(r) }
            return
        default: break
        }

        guard type == .screen, CMSampleBufferIsValid(sb) else { return }
        guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else {
            incomplete += 1
            return
        }
        guard let writer, let input,
              let retimed = Recorder.retime(sb, minus: clock.pausedOffset) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(retimed)

        if !sessionStarted {
            sessionStarted = true
            firstPTS = pts
            clock.setAnchorIfNeeded(pts)
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            webcam?.setAnchor(pts)
            events?.start()
        }

        guard input.isReadyForMoreMediaData else { return }
        input.append(retimed)
        frames += 1
        lastPTS = pts
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.line("stream stopped with error: \(error)")
    }

    /// Chooses a display by id, falling back to the main one. `displays.first`
    /// is not the main display on a multi-monitor Mac; it is whichever the
    /// system lists first, which is why this is not inlined.
    static func pickDisplay(_ content: SCShareableContent,
                            id: CGDirectDisplayID?) -> SCDisplay? {
        if let id, let match = content.displays.first(where: { $0.displayID == id }) {
            return match
        }
        let main = CGMainDisplayID()
        return content.displays.first(where: { $0.displayID == main })
            ?? content.displays.first
    }

    /// Builds the capture filter. Exclusion is matched on bundle id rather
    /// than window id, because window ids change every launch and a bundle id
    /// is something a person or a script can actually name.
    static func makeFilter(display: SCDisplay, content: SCShareableContent,
                           excludeApps: [String], onlyApp: String?) -> SCContentFilter {
        if let only = onlyApp {
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == only
            }
            if !windows.isEmpty {
                Log.line("capturing only \(only) (\(windows.count) windows)")
                return SCContentFilter(display: display,
                                       including: windows)
            }
            Log.line("no windows for \(only), capturing the whole display")
        }

        // our own windows never belong in a take: the prompter floats on top
        // while recording, and the editor could be left open
        let hidden = content.windows.filter {
            if $0.owningApplication?.processID == getpid() { return true }
            guard let id = $0.owningApplication?.bundleIdentifier else { return false }
            return excludeApps.contains(id)
        }
        if !excludeApps.isEmpty, !hidden.isEmpty {
            Log.line("excluding \(hidden.count) window(s) from \(excludeApps.joined(separator: ", "))")
        }
        return SCContentFilter(display: display, excludingWindows: hidden)
    }

    /// Shifts a sample buffer's timestamps without touching its pixels.
    static func retime(_ sb: CMSampleBuffer, minus offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sb }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0 else { return sb }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: nil) == noErr else { return sb }
        for i in 0..<count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - offset
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - offset
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sb,
                sampleTimingEntryCount: count, sampleTimingArray: &timings,
                sampleBufferOut: &out) == noErr else { return sb }
        return out
    }
}
