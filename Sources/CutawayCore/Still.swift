import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders a single composited frame. Phase 3's verification: if one frame out
/// of the real pipeline looks like a finished thumbnail, the pipeline is right.
public enum Still {

    public static func render(mov: URL, at seconds: Double,
                              outputSize: CGSize = CGSize(width: 1920, height: 1080),
                              style: Style = .default,
                              crop: CGRect? = nil,
                              to png: URL) async throws {
        let asset = AVURLAsset(url: mov)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        let (frame, actual) = try await gen.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600))
        let sourceSize = CGSize(width: frame.width, height: frame.height)
        let cropRect = crop ?? CGRect(origin: .zero, size: sourceSize)

        let engine = try RenderEngine()
        let tex = try engine.makeTexture(from: frame)
        let params = style.params(outputSize: outputSize,
                                  sourceSize: sourceSize, crop: cropRect)
        let out = try engine.render(source: tex, params: params)

        try write(out, to: png)
        Log.line("""
          still: source \(Int(sourceSize.width))x\(Int(sourceSize.height)) \
          at \(String(format: "%.3f", CMTimeGetSeconds(actual)))s \
          -> \(Int(outputSize.width))x\(Int(outputSize.height)) \
          plate \(Int(params.plate.z))x\(Int(params.plate.w)) \
          at (\(Int(params.plate.x)), \(Int(params.plate.y)))
          """)
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
