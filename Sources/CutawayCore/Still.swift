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

        let tl = timeline ?? Timeline(zooms: [], sourceSize: screenSize, cursor: [])
        let state = RenderState(screenSize: screenSize, webcamSize: webcamSize,
                                outputSize: outputSize, timeline: tl)
        let f = state.evaluate(atSourceTime: seconds)

        let engine = try RenderEngine()
        var layers: [RenderEngine.Draw] = []
        if let sp = f.screen {
            layers.append(.init(texture: try engine.makeTexture(from: screenImage), params: sp))
        }
        if let wp = f.webcam, let wi = webcamImage {
            layers.append(.init(texture: try engine.makeTexture(from: wi), params: wp))
        }

        let out = try engine.renderImage(background: f.background, layers: layers,
                                         size: outputSize)
        try write(out, to: png)
        Log.line("""
          still t=\(String(format: "%.2f", seconds))s  \
          layers=\(layers.count)  \
          screen=\(f.screen.map { "\(Int($0.dst.z))x\(Int($0.dst.w))@\(Int($0.dst.x)),\(Int($0.dst.y)) op\(String(format: "%.2f", $0.opacity))" } ?? "none")  \
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
