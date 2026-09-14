import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders one composited frame from a recording bundle. The quickest way to
/// judge a layout without waiting for a full export.
public enum Still {

    public static func render(recordingDir: URL, at seconds: Double,
                              outputSize: CGSize = CGSize(width: 1920, height: 1080),
                              timeline: Timeline? = nil,
                              preset: ExportPreset? = nil,
                              to png: URL) async throws {
        let manifest = Manifest.load(from: recordingDir.appendingPathComponent("recording.json"))

        let screenURL = recordingDir.appendingPathComponent(manifest?.screen.file ?? "display.mov")
        let (screenImage, screenSize) = try await frame(from: screenURL, at: seconds)

        var webcamImage: CGImage?
        var webcamSize: CGSize?
        if let wc = manifest?.webcam {
            // Webcam started later than the screen, so shift into its timeline.
            let wt = seconds - wc.offset
            if wt >= 0, wt <= wc.duration {
                let url = recordingDir.appendingPathComponent(wc.file)
                if let (img, size) = try? await frame(from: url, at: wt) {
                    webcamImage = img
                    webcamSize = size
                }
            }
        }

        // Fall back to the project on disk so a still always matches what the
        // preview and the export would produce.
        let tl = timeline ?? Export.loadOrCreateProject(
            recordingDir: recordingDir, screenSize: screenSize,
            duration: manifest?.screen.duration ?? 0,
            hasWebcam: manifest?.webcam != nil)
            .timeline(sourceSize: screenSize, events: Events.load(from: recordingDir),
                      sourceDuration: manifest?.screen.duration ?? 0,
                      transcript: Transcript.load(from: recordingDir))
        if let override = preset?.layoutOverride {
            tl.layouts = tl.layouts.merging(override) { _, new in new }
        }
        let state = RenderState(screenSize: screenSize, webcamSize: webcamSize,
                                outputSize: outputSize, timeline: tl)
        let f = state.evaluate(atSourceTime: seconds)

        let engine = try RenderEngine()
        engine.loadBackgroundImage(path: tl.style.background.image)
        var layers: [RenderEngine.Draw] = []
        if let sp = f.screen {
            layers.append(.init(texture: try engine.makeTexture(from: screenImage), params: sp))
        }
        if let wp = f.webcam, let wi = webcamImage {
            layers.append(.init(texture: try engine.makeTexture(from: wi), params: wp))
        }

        if let k = engine.keycastDraw(f, style: tl.keycastStyle, outputSize: outputSize) {
            layers.append(k)
        }
        if let c = engine.calloutDraw(f, theme: tl.calloutTheme,
                                      outputSize: outputSize) {
            layers.append(c)
        }
        if let cap = engine.captionDraw(f, timeline: tl,
                                        outputSize: outputSize) {
            layers.append(cap)
        }
        let layerCount = layers.count

        let out = try engine.renderImage(background: f.background, layers: layers,
                                         cursor: f.cursor, size: outputSize)
        try write(out, to: png)
        Log.line("""
          still t=\(String(format: "%.2f", seconds))s  \
          layers=\(layerCount)  \
          screen=\(f.screen.map { "\(Int($0.dst.z))x\(Int($0.dst.w))@\(Int($0.dst.x)),\(Int($0.dst.y)) op\(String(format: "%.2f", $0.opacity))" } ?? "none")  \
          keycast=\(f.keycast.map { "\"\($0.text)\" op\(String(format: "%.2f", $0.opacity))" } ?? "none")  \
          cursor=\(f.cursor.map { String(format: "rect %.0f,%.0f %.0fx%.0f op%.2f ripple r%.0f a%.2f", $0.rect.x, $0.rect.y, $0.rect.z, $0.rect.w, $0.opacity, $0.rippleRadius, $0.rippleAlpha) } ?? "NIL")  \
          webcam=\(f.webcam.map { "\(Int($0.dst.z))x\(Int($0.dst.w))@\(Int($0.dst.x)),\(Int($0.dst.y)) op\(String(format: "%.2f", $0.opacity))" } ?? "none")
          """)
    }

    static func frame(from url: URL, at seconds: Double) async throws -> (CGImage, CGSize) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (img, _) = try await gen.image(at: CMTime(seconds: max(0, seconds),
                                                     preferredTimescale: 600))
        return (img, CGSize(width: img.width, height: img.height))
    }

    static func write(_ image: CGImage, to url: URL) throws {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "cutaway", code: 7)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "cutaway", code: 8)
        }
    }
}
