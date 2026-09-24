import Foundation
import AVFoundation
import CoreGraphics

/// A short loop cut out of a longer take, made to be posted on its own: one
/// action, a few seconds, no sound. Several snippets can come out of one
/// recording, each with its own look.
public struct Snippet: Codable, Equatable {
    public var name: String
    /// Source seconds.
    public var start: Double
    public var end: Double
    public var look: Look = .framed
    public var canvas: Canvas = .feed
    /// A background preset name. nil means dusk.
    public var background: String?
    public var loop: Loop = .crossfade

    /// framed: the screen in a phone bezel on a background.
    /// bare: the screen and nothing else, edge to edge, for a page that
    /// draws its own phone around it.
    public enum Look: String, Codable, CaseIterable { case framed, bare }

    /// feed is 4:5, the tallest a post shows without cropping in the
    /// timeline. story is 9:16 for reels and stories. bare ignores this and
    /// keeps the screen's own shape.
    public enum Canvas: String, Codable, CaseIterable {
        case feed, story, square

        public var size: CGSize {
            switch self {
            case .feed: CGSize(width: 1080, height: 1350)
            case .story: CGSize(width: 1080, height: 1920)
            case .square: CGSize(width: 1080, height: 1080)
            }
        }
    }

    /// crossfade blends the last moments into the first so the loop has no
    /// jump. none plays it straight.
    public enum Loop: String, Codable, CaseIterable { case crossfade, none }

    public init(name: String, start: Double, end: Double, look: Look = .framed,
                canvas: Canvas = .feed, background: String? = nil, loop: Loop = .crossfade) {
        self.name = name
        self.start = start
        self.end = end
        self.look = look
        self.canvas = canvas
        self.background = background
        self.loop = loop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        look = (try? c.decode(Look.self, forKey: .look)) ?? .framed
        canvas = (try? c.decode(Canvas.self, forKey: .canvas)) ?? .feed
        background = try? c.decode(String.self, forKey: .background)
        loop = (try? c.decode(Loop.self, forKey: .loop)) ?? .crossfade
    }

    public var duration: Double { max(0, end - start) }

    /// A file name that survives any name typed into it.
    public var slug: String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "snippet" : joined
    }

    /// The output size for a screen of this shape.
    public func outputSize(screen: CGSize) -> CGSize {
        guard look == .bare, screen.width > 0 else { return canvas.size }
        // Same shape as the screen at 1080 wide, rounded to even numbers
        // because the encoder refuses odd ones.
        let h = (1080 * screen.height / screen.width / 2).rounded() * 2
        return CGSize(width: 1080, height: h)
    }

    /// Where the screen goes on the canvas: centred, as tall as fits with
    /// room around it for the bezel and the shadow.
    public static func phoneRect(screen: CGSize, canvas: CGSize) -> [Double] {
        let aspect = Double(screen.width / screen.height)
        var h = Double(canvas.height) * 0.80
        var w = h * aspect
        let maxW = Double(canvas.width) * 0.80
        if w > maxW { w = maxW; h = w / aspect }
        let nw = w / Double(canvas.width), nh = h / Double(canvas.height)
        return [(1 - nw) / 2, (1 - nh) / 2, nw, nh]
    }

    /// The project with this snippet's range and look applied. Everything
    /// else the take already has, like zooms or masks, carries over.
    public func apply(to base: Project, screen: CGSize) -> Project {
        var p = base
        p.trimStart = start
        p.trimEnd = end
        p.segments = []
        p.speed = 1
        p.callouts = []
        p.captions.enabled = false
        p.voiceover = nil

        let size = outputSize(screen: screen)
        p.output = .init(width: size.width, height: size.height, fps: 60)
        let placement: Placement
        switch look {
        case .framed:
            let rect = Snippet.phoneRect(screen: screen, canvas: size)
            // A real phone's screen corners are about an eighth of its width.
            var pl = Placement(rect: rect, cornerRadius: rect[2] * size.width * 0.12)
            pl.borderWidth = 0
            pl.shadowOpacity = 0.45
            placement = pl
            p.deviceFrame = base.deviceFrame == .iphone ? .iphone : .phone
            let name = background ?? "dusk"
            p.style.background = Style.presets[name] ?? Style.presets["dusk"]!
        case .bare:
            var pl = Placement(rect: [0, 0, 1, 1], cornerRadius: 0)
            pl.borderWidth = 0
            pl.shadowOpacity = 0
            placement = pl
            p.deviceFrame = .none
        }
        p.layouts["snippet"] = Layout(screen: placement, webcam: nil)
        p.scenes = [Scene(at: 0, layout: "snippet", transition: 0)]
        return p
    }
}

extension Project {

    /// A fresh phone take: the whole recording kept, a phone bezel on dusk,
    /// taps shown as touches rather than a mouse pointer, no automatic zooms
    /// because an app demo reads better held still.
    public static func makePhone(manifest: Manifest, kind: PhoneKind) -> Project {
        var p = Project()
        let screen = CGSize(width: manifest.screen.pixelSize[0],
                            height: manifest.screen.pixelSize[1])
        let canvas = Snippet.Canvas.feed.size
        p.output = .init(width: canvas.width, height: canvas.height, fps: 60)
        let rect = Snippet.phoneRect(screen: screen, canvas: canvas)
        var pl = Placement(rect: rect, cornerRadius: rect[2] * canvas.width * 0.12)
        pl.borderWidth = 0
        pl.shadowOpacity = 0.45
        p.layouts["phone"] = Layout(screen: pl, webcam: nil)
        p.scenes = [Scene(at: 0, layout: "phone", transition: 0)]
        p.deviceFrame = kind == .iphone ? .iphone : .phone
        p.backgroundPreset = "dusk"
        p.style.background = Style.presets["dusk"]!
        p.cursor.visible = false
        p.cursor.touches = true
        // grey reads on light and dark screens alike, white vanishes on light
        p.cursor.rippleColor = "#8E8E96B8"
        p.cursor.rippleDuration = 0.5
        p.motionBlur = 0
        p.notes = "Phone take. snippets: the loops to post, in source seconds. "
            + "look framed or bare, canvas feed, story or square, loop crossfade or none."
        return p
    }
}

/// Renders snippets: the video through the normal export, then a loop pass
/// and a poster frame with ffmpeg.
public enum SnippetExport {

    public struct Result {
        public var video: URL
        public var poster: URL
        public var gif: URL?
    }

    public static func run(recordingDir dir: URL, snippet: Snippet, outDir: URL,
                           gif: Bool = false) async throws -> Result {
        guard let manifest = Manifest.load(from: dir.appendingPathComponent("recording.json")),
              let base = Project.load(from: dir) else {
            throw NSError(domain: "cutaway", code: 120, userInfo: [
                NSLocalizedDescriptionKey: "no take at \(dir.path)"])
        }
        guard snippet.duration > 0.2 else {
            throw NSError(domain: "cutaway", code: 121, userInfo: [
                NSLocalizedDescriptionKey: "snippet \(snippet.name) is too short"])
        }
        let screen = CGSize(width: manifest.screen.pixelSize[0], height: manifest.screen.pixelSize[1])
        let project = snippet.apply(to: base, screen: screen)
        let size = snippet.outputSize(screen: screen)
        let tl = project.timeline(sourceSize: screen, events: Events.load(from: dir),
                                  sourceDuration: manifest.screen.duration)

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let video = outDir.appendingPathComponent("\(snippet.slug).mp4")
        let poster = outDir.appendingPathComponent("\(snippet.slug).png")
        let raw = outDir.appendingPathComponent(".\(snippet.slug).raw.mp4")

        // h264 at 60: every feed takes it, and a UI moving at 60 is most of
        // what makes these look like the app rather than a recording of it.
        let preset = ExportPreset(name: "snippet", size: size, fps: 60,
                                  codec: .h264, bitrate: 18_000_000)
        try await Export.run(recordingDir: dir, timeline: tl, preset: preset, to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }

        guard let ffmpeg = GIFEncoder.locateFFmpeg() else {
            throw NSError(domain: "cutaway", code: 122, userInfo: [
                NSLocalizedDescriptionKey: "snippets need ffmpeg (brew install ffmpeg)"])
        }
        try? FileManager.default.removeItem(at: video)
        let fade = loopFade(duration: snippet.duration)
        if snippet.loop == .crossfade, fade > 0 {
            try GIFEncoder.run(ffmpeg, ["-v", "error", "-y", "-i", raw.path,
                                        "-filter_complex", loopFilter(duration: snippet.duration, fade: fade),
                                        "-map", "[out]", "-c:v", "libx264", "-crf", "16",
                                        "-preset", "slow", "-pix_fmt", "yuv420p",
                                        "-movflags", "+faststart", "-an", video.path])
        } else {
            try FileManager.default.moveItem(at: raw, to: video)
        }
        try GIFEncoder.run(ffmpeg, ["-v", "error", "-y", "-i", video.path,
                                    "-frames:v", "1", poster.path])

        var gifURL: URL?
        if gif {
            let g = outDir.appendingPathComponent("\(snippet.slug).gif")
            try await GIFEncoder.encode(video: video, to: g, fps: 24, width: 540)
            gifURL = g
        }
        Log.line(String(format: "snippet %@: %.1fs %@ %@, %@",
                        snippet.name, snippet.duration, snippet.look.rawValue,
                        snippet.look == .bare ? "\(Int(size.width))x\(Int(size.height))"
                            : snippet.canvas.rawValue,
                        snippet.loop.rawValue))
        return Result(video: video, poster: poster, gif: gifURL)
    }

    /// Long enough to hide the seam, short enough that the blend does not
    /// read as a transition of its own.
    static func loopFade(duration: Double) -> Double {
        guard duration >= 1.2 else { return 0 }
        return min(0.5, duration / 5)
    }

    /// Plays from `fade` to the end, and over the last `fade` seconds blends
    /// in the opening, so the last frame is the first frame and the loop has
    /// no seam. The result is `fade` shorter than the snippet.
    static func loopFilter(duration d: Double, fade f: Double) -> String {
        let head = String(format: "%.3f", f)
        let offset = String(format: "%.3f", d - 2 * f)
        return "[0:v]split[a][b];"
            + "[a]trim=0:\(head),setpts=PTS-STARTPTS[head];"
            + "[b]trim=\(head),setpts=PTS-STARTPTS[body];"
            + "[body][head]xfade=transition=fade:duration=\(head):offset=\(offset),format=yuv420p[out]"
    }
}
