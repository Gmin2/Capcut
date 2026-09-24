import Foundation
import CoreGraphics

/// The edit, as a file.
///
/// This is the whole point of the architecture: the entire creative decision
/// set is plain JSON with stable ids, explicit units and seconds rather than
/// frame numbers. The app writes a sensible default on first open, then anyone
/// (you, the UI, or Claude reading events.json and a transcript) can rewrite it
/// and the preview reloads. No pixels need to be looked at to edit this video.
public struct Project: Codable {
    public var version = 1
    public var notes: String?
    public var output = Output()
    public var style = Style.default
    public var scenes: [Scene] = []
    public var zooms: [Zoom] = []
    /// Kept spans of the recording. Empty means keep everything.
    public var segments: [Segment] = []
    /// Top and tail. You always start recording before you are ready and stop
    /// after you have finished, so this is the first edit anyone makes.
    public var trimStart: Double = 0
    /// nil runs to the end of the recording.
    public var trimEnd: Double?
    public var cursor = CursorStyle()
    public var audio = AudioSettings()
    public var keycast = KeycastStyle()
    public var callouts: [Callout] = []
    public var calloutTheme = CalloutTheme()
    public var captions = CaptionStyle()
    /// "none", "macWindow", "browser", "phone" or "iphone", drawn around the
    /// screen layer.
    public var deviceFrame: DeviceFrame = .none
    /// Extra or replacement layouts by name, for framing the built-in ones do
    /// not cover, like a portrait phone recording filling a tall canvas.
    public var layouts: [String: Layout] = [:]
    public var masks: [Mask] = []
    /// 0 off, 1 is roughly a film shutter.
    public var motionBlur: Double = 0.85
    /// Speed for the whole take, on top of whatever each cut span already
    /// does. 1.25 is the usual demo trick: brisk without sounding silly.
    public var speed: Double = 1
    /// Shorthand for style.background. Names: midnight, slate, ember, forest,
    /// paper, ink, dusk, screen.
    public var backgroundPreset: String?
    public var voiceover: Voiceover?
    /// Short loops cut out of this take to post on their own.
    public var snippets: [Snippet] = []

    public struct Output: Codable {
        public var width: Double = 1920
        public var height: Double = 1080
        public var fps: Int = 60
        public var size: CGSize { CGSize(width: width, height: height) }
    }

    public static let filename = "project.json"

    /// Hand-written so every field is optional on the way in. The synthesised
    /// decoder demands all keys, which would make each new feature invalidate
    /// every project file that already exists, including hand-edited ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        version = get(.version, 1)
        notes = try? c.decode(String.self, forKey: .notes)
        output = get(.output, Output())
        style = get(.style, Style.default)
        // A preset name is shorthand for a whole background block, so a
        // project can say "screen" instead of spelling out five fields.
        if let preset = try? c.decode(String.self, forKey: .backgroundPreset),
           let g = Style.presets[preset] {
            style.background = g
        }
        scenes = get(.scenes, [])
        zooms = get(.zooms, [])
        segments = get(.segments, [])
        trimStart = get(.trimStart, 0)
        trimEnd = try? c.decode(Double.self, forKey: .trimEnd)
        cursor = get(.cursor, CursorStyle())
        audio = get(.audio, AudioSettings())
        keycast = get(.keycast, KeycastStyle())
        callouts = get(.callouts, [])
        calloutTheme = get(.calloutTheme, CalloutTheme())
        captions = get(.captions, CaptionStyle())
        deviceFrame = get(.deviceFrame, DeviceFrame.none)
        layouts = get(.layouts, [:])
        masks = get(.masks, [])
        motionBlur = get(.motionBlur, 0.85)
        speed = get(.speed, 1)
        backgroundPreset = try? c.decode(String.self, forKey: .backgroundPreset)
        voiceover = try? c.decode(Voiceover.self, forKey: .voiceover)
        snippets = get(.snippets, [])
    }

    public init() {}

    public static func load(from dir: URL) -> Project? {
        let url = dir.appendingPathComponent(filename)
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Project.self, from: d)
        } catch {
            // Loud, and deliberately not overwritten: silently replacing a file
            // someone is editing loses their work.
            Log.line("project.json is invalid, keeping it and using defaults: \(error)")
            return nil
        }
    }

    /// True when a file is present, whether or not it parses. Used to decide
    /// if writing a fresh default is safe.
    public static func exists(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(filename).path)
    }

    public func write(to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: dir.appendingPathComponent(Project.filename))
    }

    /// First-open defaults, derived from what actually happened during the
    /// recording rather than from a template.
    /// A project shaped like a pitch video: open on the face, hand over to the
    /// screen, name and role on screen, zooms placed from the clicks. Written
    /// as a starting point to edit, not as a finished result.
    public static func makePitch(recordingDir: URL, manifest: Manifest,
                                 name: String, role: String) -> Project {
        var p = makeDefault(recordingDir: recordingDir, manifest: manifest)
        let d = manifest.screen.duration
        let handover = min(max(d * 0.28, 3), d - 2)

        p.scenes = manifest.webcam != nil
            ? [Scene(at: 0, layout: "talkingHead"),
               Scene(at: handover, layout: "demo", transition: 0.8)]
            : [Scene(at: 0, layout: "screenOnly")]

        p.callouts = [
            Callout(at: 0.8, text: name, subtitle: role,
                    duration: min(4.0, max(2.5, handover - 1)), style: "lowerThird"),
        ]
        p.backgroundPreset = "midnight"
        p.deviceFrame = .macWindow
        p.notes = """
            Pitch template. Edit freely; the app reloads this file as you save.
            scenes: when the picture changes. zooms: source-time camera moves.
            callouts: text on screen. voiceover: synthesised narration.
            """
        return p
    }

    public static func makeDefault(recordingDir: URL, manifest: Manifest) -> Project {
        var p = Project()
        let screenSize = CGSize(width: manifest.screen.pixelSize[0],
                                height: manifest.screen.pixelSize[1])
        let ev = Events.load(from: recordingDir)
        p.zooms = AutoZoom.generate(clicks: ev.clicks, sourceSize: screenSize,
                                    duration: manifest.screen.duration)
        // Cutting quiet time needs something to judge quiet by. With no speech
        // and no clicks, a talking-head take looks idle from end to end and
        // gets cut down to nothing, so leave it whole instead.
        let transcript = Transcript.load(from: recordingDir)
        p.segments = transcript != nil || !ev.clicks.isEmpty
            ? AutoCut.segments(events: ev, transcript: transcript,
                               duration: manifest.screen.duration)
            : []
        p.scenes = manifest.webcam != nil
            ? [Scene(at: 0, layout: "talkingHead"),
               Scene(at: manifest.screen.duration * 0.35, layout: "demo", transition: 0.8)]
            : [Scene(at: 0, layout: "screenOnly")]
        p.notes = "Edit this file and the preview reloads. "
            + "Times are seconds in source time. Layouts: "
            + Layout.named.keys.sorted().joined(separator: ", ")
        return p
    }

    /// Clips the kept spans to the trim range. Trim is expressed separately
    /// from cuts so dragging the ends never rewrites the cut list, but by the
    /// time it reaches the renderer it is all just segments.
    func trimmedSegments(sourceDuration: Double) -> [Segment] {
        let lo = max(0, trimStart)
        let hi = min(trimEnd ?? sourceDuration, sourceDuration)
        guard hi > lo else {
            return segments.map {
                var s = $0
                s.speed *= max(speed, 0.1)
                return s
            }
        }

        let base = segments.isEmpty
            ? [Segment(sourceStart: 0, sourceEnd: sourceDuration)]
            : segments
        return base.compactMap { s in
            let a = max(s.sourceStart, lo)
            let b = min(s.sourceEnd, hi)
            guard b > a + 0.01 else { return nil }
            var out = s
            out.sourceStart = a
            out.sourceEnd = b
            out.speed = s.speed * max(speed, 0.1)
            return out
        }
    }

    public func timeline(sourceSize: CGSize, events: Events,
                         sourceDuration: Double = 0,
                         transcript: Transcript? = nil) -> Timeline {
        let tl = Timeline(zooms: zooms, sourceSize: sourceSize, cursor: events.cursor)
        tl.scenes = scenes.isEmpty ? [Scene(at: 0, layout: "screenOnly")] : scenes
        tl.style = style
        tl.cursorStyle = self.cursor
        tl.clicks = events.clicks
        tl.keycastStyle = keycast
        tl.setKeys(events.keys)
        tl.callouts = callouts
        tl.calloutTheme = calloutTheme
        tl.captionStyle = captions
        tl.setTranscript(transcript)
        tl.deviceFrame = deviceFrame
        tl.layouts = Layout.named.merging(layouts) { _, new in new }
        tl.masks = masks
        tl.motionBlur = motionBlur
        tl.timeMap = TimeMap(segments: trimmedSegments(sourceDuration: sourceDuration),
                             sourceDuration: sourceDuration)
        tl.trimStart = trimStart
        tl.trimEnd = trimEnd ?? sourceDuration
        return tl
    }
}

/// Convenience wrapper so callers do not repeat the decode dance.
public struct Events {
    public var clicks: [(t: Double, p: CGPoint)] = []
    public var cursor: [(t: Double, p: CGPoint)] = []
    public var keys: [EventRecorder.Key] = []

    public static func load(from dir: URL) -> Events {
        var e = Events()
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
              let ev = try? JSONDecoder().decode(EventRecorder.Events.self, from: d)
        else { return e }
        e.clicks = ev.clicks.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
        e.cursor = ev.cursor.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
        e.keys = ev.keys
        return e
    }
}

/// Watches one file and calls back on change. Used so an external editor,
/// including an AI writing project.json, updates the preview live.
public final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let onChange: () -> Void

    public init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    private func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            self.onChange()
            // Most editors replace rather than write in place, so the old
            // descriptor stops receiving events and the watch must be rebuilt.
            if flags.contains(.rename) || flags.contains(.delete) {
                self.source?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.start() }
            }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    deinit { source?.cancel() }
}
