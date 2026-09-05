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
    public private(set) var duration: Double = 0
    public private(set) var currentTime: Double = 0
    public var onTimeChange: ((Double) -> Void)?
    private(set) public var framesDrawn = 0

    public var isPlaying: Bool { screenPlayer?.rate ?? 0 > 0 }

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
        duration = manifest?.screen.duration ?? 0
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
        guard let screenPlayer else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        screenPlayer.play()
        webcamPlayer?.play()
    }

    public func pause() {
        screenPlayer?.pause()
        webcamPlayer?.pause()
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    public func seek(to t: Double) {
        let clamped = min(max(t, 0), max(duration, 0))
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        screenPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        // The camera started later, so its own timeline is shifted.
        webcamPlayer?.seek(to: CMTime(seconds: max(0, clamped - webcamOffset),
                                      preferredTimescale: 600),
                           toleranceBefore: .zero, toleranceAfter: .zero)
        onTimeChange?(clamped)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let state,
              let drawable = view.currentDrawable else { return }

        if isPlaying, let p = screenPlayer {
            currentTime = CMTimeGetSeconds(p.currentTime())
            onTimeChange?(currentTime)
            if currentTime >= duration - 0.01 { pause() }
        }

        let f = state.evaluate(atSourceTime: currentTime)
        var layers: [RenderEngine.Draw] = []

        if let sp = f.screen, let out = screenOutput {
            let it = CMTime(seconds: currentTime, preferredTimescale: 600)
            if let pb = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil),
               let tex = engine.texture(from: pb) {
                lastScreen = tex
            }
            if let tex = lastScreen { layers.append(.init(texture: tex, params: sp)) }
        }
        if let wp = f.webcam, let out = webcamOutput {
            let it = CMTime(seconds: max(0, currentTime - webcamOffset), preferredTimescale: 600)
            if let pb = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil),
               let tex = engine.texture(from: pb) {
                lastWebcam = tex
            }
            if let tex = lastWebcam { layers.append(.init(texture: tex, params: wp)) }
        }

        engine.draw(background: f.background, layers: layers, cursor: f.cursor,
                    into: drawable.texture, present: drawable)
        framesDrawn += 1
    }

    /// Decoders do not always have a buffer ready on the exact frame we ask
    /// for, so the last good texture is held rather than flashing empty.
    private var lastScreen: MTLTexture?
    private var lastWebcam: MTLTexture?
}
