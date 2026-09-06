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
    public var cursor = CursorStyle()
    public var audio = AudioSettings()
    public var voiceover: Voiceover?

    public struct Output: Codable {
        public var width: Double = 1920
        public var height: Double = 1080
        public var fps: Int = 60
        public var size: CGSize { CGSize(width: width, height: height) }
    }

    public static let filename = "project.json"

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
    public static func makeDefault(recordingDir: URL, manifest: Manifest) -> Project {
        var p = Project()
        let screenSize = CGSize(width: manifest.screen.pixelSize[0],
                                height: manifest.screen.pixelSize[1])
        let ev = Events.load(from: recordingDir)
        p.zooms = AutoZoom.generate(clicks: ev.clicks, sourceSize: screenSize,
                                    duration: manifest.screen.duration)
        p.segments = AutoCut.segments(events: ev,
                                      transcript: Transcript.load(from: recordingDir),
                                      duration: manifest.screen.duration)
        p.scenes = manifest.webcam != nil
            ? [Scene(at: 0, layout: "talkingHead"),
               Scene(at: manifest.screen.duration * 0.35, layout: "demo", transition: 0.8)]
            : [Scene(at: 0, layout: "screenOnly")]
        p.notes = "Edit this file and the preview reloads. "
            + "Times are seconds in source time. Layouts: "
            + Layout.named.keys.sorted().joined(separator: ", ")
        return p
    }

    public func timeline(sourceSize: CGSize, events: Events,
                         sourceDuration: Double = 0) -> Timeline {
        let tl = Timeline(zooms: zooms, sourceSize: sourceSize, cursor: events.cursor)
        tl.scenes = scenes.isEmpty ? [Scene(at: 0, layout: "screenOnly")] : scenes
        tl.style = style
        tl.cursorStyle = self.cursor
        tl.clicks = events.clicks
        tl.timeMap = TimeMap(segments: segments, sourceDuration: sourceDuration)
        return tl
    }
}

/// Convenience wrapper so callers do not repeat the decode dance.
public struct Events {
    public var clicks: [(t: Double, p: CGPoint)] = []
    public var cursor: [(t: Double, p: CGPoint)] = []

    public static func load(from dir: URL) -> Events {
        var e = Events()
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
              let ev = try? JSONDecoder().decode(EventRecorder.Events.self, from: d)
        else { return e }
        e.clicks = ev.clicks.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
        e.cursor = ev.cursor.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
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
