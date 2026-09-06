import Foundation
import AVFoundation
import MetalKit
import AppKit

/// Live scrubbable preview. Two AVPlayers feed pixel buffers into the same
/// RenderEngine the export uses, so what you see here is what you get out.
///
/// The players exist only to decode and seek; all compositing is ours. That is
/// why a custom AVVideoCompositor is not needed for two tracks.
public final class PreviewController: NSObject, MTKViewDelegate {

    public let view: MTKView
    private let engine: RenderEngine

    private var screenPlayer: AVPlayer?
    private var webcamPlayer: AVPlayer?
    private var screenOutput: AVPlayerItemVideoOutput?
    private var webcamOutput: AVPlayerItemVideoOutput?
    private var webcamOffset: Double = 0

    private var state: RenderState?
    private var timeMap = TimeMap(segments: [], sourceDuration: 0)
    /// Length of the edit, not of the raw recording.
    public private(set) var duration: Double = 0
    public private(set) var sourceDuration: Double = 0
    /// Position in edited time; `sourceTime` is where that lands in the media.
    public private(set) var currentTime: Double = 0
    public var sourceTime: Double { timeMap.sourceTime(forOutput: currentTime) }

    /// Nearest playable output time for a source moment, so clicking a cut
    /// span on the timeline lands on the next kept frame rather than nowhere.
    public func outputTime(forSource t: Double) -> Double {
        if let exact = timeMap.outputTime(forSource: t) { return exact }
        var best = 0.0, bestDelta = Double.greatestFiniteMagnitude
        for s in timeMap.segments {
            for candidate in [s.sourceStart, s.sourceEnd] {
                let d = abs(candidate - t)
                if d < bestDelta, let o = timeMap.outputTime(forSource: candidate) {
                    bestDelta = d
                    best = o
                }
            }
        }
        return best
    }
    private var playStart = Date()
    private var playFrom: Double = 0
    public var onTimeChange: ((Double) -> Void)?
    private(set) public var framesDrawn = 0

    public var isPlaying: Bool { playing }

    public init(engine: RenderEngine) {
        self.engine = engine
        view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        super.init()
        view.delegate = self
    }

    public func load(recordingDir: URL, outputSize: CGSize, timeline: Timeline,
                     screenSize: CGSize, webcamSize: CGSize?) {
        let manifest = Manifest.load(from: recordingDir.appendingPathComponent("recording.json"))
        sourceDuration = manifest?.screen.duration ?? 0
        timeMap = timeline.timeMap
        duration = timeMap.outputDuration > 0 ? timeMap.outputDuration : sourceDuration
        webcamOffset = manifest?.webcam?.offset ?? 0

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let screenURL = recordingDir.appendingPathComponent(manifest?.screen.file ?? "display.mov")
        let sItem = AVPlayerItem(url: screenURL)
        let sOut = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        sItem.add(sOut)
        screenOutput = sOut
        screenPlayer = AVPlayer(playerItem: sItem)
        screenPlayer?.actionAtItemEnd = .pause

        if let wc = manifest?.webcam {
            let wItem = AVPlayerItem(url: recordingDir.appendingPathComponent(wc.file))
            let wOut = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            wItem.add(wOut)
            webcamOutput = wOut
            webcamPlayer = AVPlayer(playerItem: wItem)
            webcamPlayer?.actionAtItemEnd = .pause
        }

        state = RenderState(screenSize: screenSize, webcamSize: webcamSize,
                            outputSize: outputSize, timeline: timeline)
        seek(to: 0)
    }

    public func play() {
        guard screenPlayer != nil else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        // Edited time is driven by our own clock rather than the player's,
        // because a cut makes output time and media time diverge. The players
        // are seeked per frame instead of played.
        playFrom = currentTime
        playStart = Date()
        playing = true
    }

    public func pause() {
        playing = false
        screenPlayer?.pause()
        webcamPlayer?.pause()
    }

    private var playing = false

    public func togglePlay() { isPlaying ? pause() : play() }

    public func seek(to t: Double) {
        let clamped = min(max(t, 0), max(duration, 0))
        currentTime = clamped
        playFrom = clamped
        playStart = Date()
        let time = CMTime(seconds: timeMap.sourceTime(forOutput: clamped),
                          preferredTimescale: 600)
        screenPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        // The camera started later, so its own timeline is shifted.
        webcamPlayer?.seek(to: CMTime(seconds: max(0, CMTimeGetSeconds(time) - webcamOffset),
                                      preferredTimescale: 600),
                           toleranceBefore: .zero, toleranceAfter: .zero)
        onTimeChange?(clamped)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let state,
              let drawable = view.currentDrawable else { return }

        if playing {
            currentTime = playFrom + Date().timeIntervalSince(playStart)
            if currentTime >= duration - 0.01 { currentTime = duration; pause() }
            onTimeChange?(currentTime)
        }

        let src = timeMap.sourceTime(forOutput: currentTime)

        // The decoders only produce buffers for times they have been moved to,
        // so playback nudges them along rather than letting them run free.
        // Cheap because seeking forward within a decoded range is nearly free.
        if playing, abs(src - lastSeek) > 0.02 {
            lastSeek = src
            let time = CMTime(seconds: src, preferredTimescale: 600)
            screenPlayer?.seek(to: time, toleranceBefore: .zero,
                               toleranceAfter: CMTime(value: 1, timescale: 30))
            webcamPlayer?.seek(to: CMTime(seconds: max(0, src - webcamOffset),
                                          preferredTimescale: 600),
                               toleranceBefore: .zero,
                               toleranceAfter: CMTime(value: 1, timescale: 30))
        }

        let f = state.evaluate(atSourceTime: src)
        var layers: [RenderEngine.Draw] = []

        if let sp = f.screen, let out = screenOutput {
            let it = CMTime(seconds: src, preferredTimescale: 600)
            if let pb = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil),
               let tex = engine.texture(from: pb) {
                lastScreen = tex
            }
            if let tex = lastScreen { layers.append(.init(texture: tex, params: sp)) }
        }
        if let wp = f.webcam, let out = webcamOutput {
            let it = CMTime(seconds: max(0, src - webcamOffset), preferredTimescale: 600)
            if let pb = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil),
               let tex = engine.texture(from: pb) {
                lastWebcam = tex
            }
            if let tex = lastWebcam { layers.append(.init(texture: tex, params: wp)) }
        }

        if let k = engine.keycastDraw(f, style: state.timeline.keycastStyle,
                                      outputSize: state.outputSize) {
            layers.append(k)
        }
        if let c = engine.calloutDraw(f, theme: state.timeline.calloutTheme,
                                      outputSize: state.outputSize) {
            layers.append(c)
        }

        engine.draw(background: f.background, layers: layers, cursor: f.cursor,
                    into: drawable.texture, present: drawable)
        framesDrawn += 1
    }

    /// Decoders do not always have a buffer ready on the exact frame we ask
    /// for, so the last good texture is held rather than flashing empty.
    private var lastSeek: Double = -1
    private var lastScreen: MTLTexture?
    private var lastWebcam: MTLTexture?
}
