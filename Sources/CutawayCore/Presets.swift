import Foundation
import AVFoundation
import CoreGraphics

/// A named output format. The same recording and the same project.json can be
/// rendered to any of these; only the canvas and the framing change.
public struct ExportPreset {
    public var name: String
    public var size: CGSize
    public var fps: Int32
    public var codec: AVVideoCodecType
    public var bitrate: Int
    /// Layouts to use instead of whatever the scenes name. Vertical output
    /// needs its own framing: a 16:10 screen letterboxed into 9:16 would be a
    /// thin strip with two thirds of the frame empty.
    public var layoutOverride: [String: Layout]?
    /// Animated GIF rather than video. Needs a palette pass, so it goes through
    /// a different path at the end.
    public var isGIF = false

    public static let hd = ExportPreset(
        name: "1080p", size: CGSize(width: 1920, height: 1080), fps: 60,
        codec: .hevc, bitrate: 12_000_000)

    public static let uhd = ExportPreset(
        name: "4K", size: CGSize(width: 3840, height: 2160), fps: 60,
        codec: .hevc, bitrate: 45_000_000)

    /// H.264 rather than HEVC: still the safer bet for anything that has to
    /// play everywhere without a codec argument.
    public static let compatible = ExportPreset(
        name: "1080p-h264", size: CGSize(width: 1920, height: 1080), fps: 60,
        codec: .h264, bitrate: 16_000_000)

    /// Portrait for social. The screen fills the width and sits high, leaving
    /// room for the camera beneath it rather than shrinking both.
    public static let vertical = ExportPreset(
        name: "vertical", size: CGSize(width: 1080, height: 1920), fps: 60,
        codec: .hevc, bitrate: 14_000_000,
        layoutOverride: [
            // Centred: with no camera there is nothing to fill the lower
            // third, and a plate parked high just looks like a mistake.
            "screenOnly": Layout(
                screen: Placement(rect: [0.03, 0.29, 0.94, 0.42]),
                webcam: nil),
            "demo": Layout(
                screen: Placement(rect: [0.03, 0.14, 0.94, 0.42]),
                webcam: Placement(rect: [0.20, 0.60, 0.60, 0.26],
                                  fit: "fill", circle: true)),
            "talkingHead": Layout(
                screen: nil,
                webcam: Placement(rect: [0, 0, 1, 1], fit: "fill", cornerRadius: 0)),
            "sideBySide": Layout(
                screen: Placement(rect: [0.03, 0.10, 0.94, 0.40]),
                webcam: Placement(rect: [0.03, 0.54, 0.94, 0.36],
                                  fit: "fill", cornerRadius: 28)),
        ])

    /// Square, for feeds that crop everything else.
    public static let square = ExportPreset(
        name: "square", size: CGSize(width: 1080, height: 1080), fps: 60,
        codec: .hevc, bitrate: 12_000_000,
        layoutOverride: [
            "screenOnly": Layout(
                screen: Placement(rect: [0.04, 0.22, 0.92, 0.56]), webcam: nil),
            
            "demo": Layout(
                screen: Placement(rect: [0.04, 0.16, 0.92, 0.56]),
                webcam: Placement(rect: [0.30, 0.72, 0.40, 0.22],
                                  fit: "fill", circle: true)),
        ])

    /// 15fps and half size, because a GIF at 60fps is enormous and nobody can
    /// see the difference in a loop.
    public static let gif = ExportPreset(
        name: "gif", size: CGSize(width: 960, height: 540), fps: 15,
        codec: .hevc, bitrate: 8_000_000, isGIF: true)

    public static let named: [String: ExportPreset] = [
        "1080p": .hd, "hd": .hd,
        "4k": .uhd, "uhd": .uhd,
        "h264": .compatible, "compatible": .compatible,
        "vertical": .vertical, "9:16": .vertical, "reel": .vertical,
        "square": .square, "1:1": .square,
        "gif": .gif,
    ]

    public static var allNames: [String] {
        ["1080p", "4k", "h264", "vertical", "square", "gif"]
    }
}

/// GIF encoding, as a second pass over a rendered video.
///
/// Two passes over the frames: one to build a palette that suits the whole
/// clip, one to map to it. A per-frame palette produces visible colour churn
/// on gradients, which is exactly what our backgrounds are.
public enum GIFEncoder {

    public static func encode(video: URL, to out: URL, fps: Int32,
                              width: Int) async throws {
        guard let ffmpeg = locateFFmpeg() else {
            throw NSError(domain: "cutaway", code: 90, userInfo: [
                NSLocalizedDescriptionKey:
                    "GIF export needs ffmpeg on PATH (brew install ffmpeg)"])
        }
        let palette = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutaway-palette-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: palette) }

        let filters = "fps=\(fps),scale=\(width):-1:flags=lanczos"
        try run(ffmpeg, ["-v", "error", "-y", "-i", video.path,
                         "-vf", "\(filters),palettegen=stats_mode=diff",
                         palette.path])
        try run(ffmpeg, ["-v", "error", "-y", "-i", video.path, "-i", palette.path,
                         "-lavfi", "\(filters)[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3",
                         "-loop", "0", out.path])

        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
        Log.line(String(format: "gif: %dpx @%dfps, %.1f MB",
                        width, fps, Double(size) / 1_048_576))
    }

    static func locateFFmpeg() -> URL? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    static func run(_ tool: URL, _ args: [String]) throws {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            throw NSError(domain: "cutaway", code: 91, userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg failed: \(text.prefix(300))"])
        }
    }
}
