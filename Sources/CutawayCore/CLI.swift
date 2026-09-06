import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit

/// Headless entry points.
///
/// The point of this file is that everything Cutaway does is scriptable: an
/// agent can record, inspect what happened, rewrite the edit and export, all
/// without a window. It is the same code the UI calls, so the two cannot drift.
public enum CLI {

    public static func run(_ args: [String]) async -> Int32 {
        var args = args
        if let i = args.firstIndex(of: "--cli-out"), i + 1 < args.count {
            outPath = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        args.removeAll { $0 == childMarker }
        let command = args.isEmpty ? "help" : args.removeFirst()

        do {
            switch command {
            case "record":   return try await record(args)
            case "export":   return try await export(args)
            case "describe": return try describe(args)
            case "still":    return try await still(args)
            case "snap":     return try await snap(args)
            case "doctor":   return await doctor()
            case "pitch":    return try pitch(args)
            case "pack":     return try pack(args)
            case "trim":     return try trim(args)
            case "windows":  return try await windows()
            case "voices":   return voices()
            case "help", "--help", "-h": usage(); return 0
            default:
                FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
                usage()
                return 1
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Commands that touch the screen, camera or microphone. Everything else
    /// is pure file work and runs fine in-process.
    static let childMarker = "--cutaway-child"

    static func needsAppLaunch(_ args: [String]) -> Bool {
        ["record", "snap", "doctor", "windows"].contains(args.first ?? "")
    }

    /// Runs this same bundle as an app and forwards its output.
    ///
    /// The request goes through a file, not through arguments: `open --args`
    /// silently delivers nothing on this system, and the environment is not
    /// inherited through LaunchServices either. A file is the only channel that
    /// actually survives, and it is one we control both ends of.
    static func relaunchThroughBundle(_ args: [String], timeout: Double = 90) -> Int32 {
        let bundle = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // Cutaway.app

        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutaway-cli-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)

        let request: [String: Any] = ["args": args, "out": outFile.path]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return 1 }
        try? FileManager.default.createDirectory(
            at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: pendingURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-a", bundle.path]
        do { try p.run() } catch {
            FileHandle.standardError.write(Data("relaunch failed: \(error)\n".utf8))
            return 1
        }

        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        while Date() < deadline {
            if let t = try? String(contentsOf: outFile, encoding: .utf8), !t.isEmpty {
                text = t
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        try? FileManager.default.removeItem(at: pendingURL)
        try? FileManager.default.removeItem(at: outFile)

        guard !text.isEmpty else {
            FileHandle.standardError.write(Data(
                "no result from the app after \(Int(timeout))s\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(Data(text.utf8))
        return 0
    }

    static var pendingURL: URL {
        URL(fileURLWithPath: NSString(
            string: "~/Library/Application Support/Cutaway/pending.json")
            .expandingTildeInPath)
    }

    /// Picked up on launch when the CLI asked the app to do something. Returns
    /// the command to run, having consumed the request.
    public static func takePendingRequest() -> [String]? {
        guard let data = try? Data(contentsOf: pendingURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let args = obj["args"] as? [String] else { return nil }
        outPath = obj["out"] as? String
        try? FileManager.default.removeItem(at: pendingURL)
        return args
    }

    /// stdout is a pipe file when running as a relaunched child, since a
    /// process started by `open` has no terminal attached.
    nonisolated(unsafe) static var outPath: String?

    static func emit(_ s: String) {
        if let path = outPath, let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((s + "\n").utf8))
            try? handle.close()
        } else {
            print(s)
        }
    }

    static func usage() {
        print("""
        cutaway <command>

          record [--seconds N] [--out DIR] [--no-webcam] [--no-mic]
                 [--system-audio] [--keys] [--countdown N]
                 [--exclude bundle.id,...] [--only bundle.id]
              Records the screen, then writes display.mov, events.json,
              recording.json, transcript.json and a default project.json.
              --keys logs keystrokes for the overlay; needs Input Monitoring.
              --exclude keeps an app's windows out of the capture entirely.
              --only captures just one app instead of the whole display.
              Use `cutaway windows` to find bundle ids.

          export [--in DIR] [--out FILE] [--preset NAME] [--all]
                 [--width N] [--height N] [--fps N]
              Renders the edit described by project.json.
              Presets: 1080p, 4k, h264, vertical, square, gif.
              --all writes every preset next to the output file.

          describe [--in DIR] [--json]
              Prints what is in a recording: duration, tracks, clicks, cuts,
              zooms, scenes and the transcript. Start here before editing.

          still --at T[,T2,...] [--in DIR] [--out FILE] [--preset NAME]
              Renders composited frames to PNG. Much faster than an export
              when checking a layout or an overlay.

          pitch --name "Your Name" --role "Your Role" [--in DIR]
              Rewrites project.json as a pitch video: webcam opening, handover
              to the screen, lower third, auto zooms, device frame.

          doctor
              Checks every permission and dependency, and says how to fix
              whatever is missing. Start here when something silently does
              nothing.

          pack [--in DIR] [--out FILE.cutaway]
              Wraps a recording into a single .cutaway document.

          trim [--in DIR]
              Deletes the raw capture, keeping the edit and the event log.
              Do this once an export is approved; raw media is most of the size.

          snap [--out FILE]
              Screenshots the display through the app's capture grant.

          windows
              Lists open windows and their bundle ids, for --exclude and --only.

          voices
              Lists installed speech voices for project.json voiceover.

        Editing is done by rewriting project.json. Times are seconds in source
        time; the app hot-reloads the file if it is open.
        """)
    }

    // MARK: commands

    static func record(_ args: [String]) async throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--out") ?? defaultDir
        let seconds = opts.double("--seconds") ?? 10

        let r = Recorder()
        r.captureWebcam = !opts.flag("--no-webcam")
        r.captureMicrophone = !opts.flag("--no-mic")
        r.captureSystemAudio = opts.flag("--system-audio")
        r.captureKeys = opts.flag("--keys")
        r.excludeApps = (opts.value("--exclude") ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        r.onlyApp = opts.value("--only")

        try await r.start(to: dir.appendingPathComponent("display.mov"))
        // A CLI recording is unattended, so it runs for a fixed span rather
        // than waiting for a Stop button.
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        _ = try await r.stop()

        if let m = Manifest.load(from: dir.appendingPathComponent("recording.json")) {
            _ = Export.loadOrCreateProject(
                recordingDir: dir,
                screenSize: CGSize(width: m.screen.pixelSize[0], height: m.screen.pixelSize[1]),
                duration: m.screen.duration, hasWebcam: m.webcam != nil)
        }
        emit(dir.path)
        return 0
    }

    static func export(_ args: [String]) async throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        let out = opts.url("--out") ?? dir.appendingPathComponent("export.mp4")

        if opts.flag("--all") {
            for name in ExportPreset.allNames {
                guard var p = ExportPreset.named[name] else { continue }
                if let w = opts.double("--fps") { p.fps = Int32(w) }
                let ext = p.isGIF ? "gif" : "mp4"
                let target = out.deletingPathExtension()
                    .appendingPathExtension("\(p.name).\(ext)")
                try await Export.run(recordingDir: dir, preset: p, to: target)
                emit(target.path)
            }
            return 0
        }

        var preset: ExportPreset
        if let name = opts.value("--preset") {
            guard let p = ExportPreset.named[name.lowercased()] else {
                FileHandle.standardError.write(Data(
                    "unknown preset: \(name). try: \(ExportPreset.allNames.joined(separator: ", "))\n".utf8))
                return 1
            }
            preset = p
        } else {
            preset = ExportPreset(
                name: "custom",
                size: CGSize(width: opts.double("--width") ?? 1920,
                             height: opts.double("--height") ?? 1080),
                fps: 60, codec: .hevc, bitrate: 12_000_000)
        }
        if let f = opts.double("--fps") { preset.fps = Int32(f) }

        // Keep the extension honest: a GIF written to .mp4 confuses everything
        // downstream.
        var target = out
        if preset.isGIF, out.pathExtension.lowercased() != "gif" {
            target = out.deletingPathExtension().appendingPathExtension("gif")
        }
        try await Export.run(recordingDir: dir, preset: preset, to: target)
        emit(target.path)
        return 0
    }

    static func describe(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        guard let m = Manifest.load(from: dir.appendingPathComponent("recording.json")) else {
            FileHandle.standardError.write(Data("no recording in \(dir.path)\n".utf8))
            return 1
        }
        let screenSize = CGSize(width: m.screen.pixelSize[0], height: m.screen.pixelSize[1])
        let events = Events.load(from: dir)
        let transcript = Transcript.load(from: dir)
        let project = Export.loadOrCreateProject(recordingDir: dir, screenSize: screenSize,
                                                 duration: m.screen.duration,
                                                 hasWebcam: m.webcam != nil)
        let map = TimeMap(segments: project.segments, sourceDuration: m.screen.duration)

        if opts.flag("--json") {
            let summary: [String: Any] = [
                "duration": m.screen.duration,
                "outputDuration": map.outputDuration,
                "screen": ["width": screenSize.width, "height": screenSize.height],
                "hasWebcam": m.webcam != nil,
                "hasMic": m.mic != nil,
                "clicks": events.clicks.count,
                "zooms": project.zooms.count,
                "scenes": project.scenes.map { ["at": $0.at, "layout": $0.layout] },
                "segments": project.segments.map {
                    ["from": $0.sourceStart, "to": $0.sourceEnd, "speed": $0.speed]
                },
                "transcript": transcript?.text ?? "",
            ]
            let data = try JSONSerialization.data(withJSONObject: summary,
                                                  options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "")
            return 0
        }

        print("""
        recording   \(dir.path)
        duration    \(fmt(m.screen.duration))s source -> \(fmt(map.outputDuration))s edited
        screen      \(Int(screenSize.width))x\(Int(screenSize.height))
        webcam      \(m.webcam.map { "\(Int($0.pixelSize[0]))x\(Int($0.pixelSize[1])), starts +\(fmt($0.offset))s" } ?? "none")
        mic         \(m.mic.map { "\(fmt($0.duration))s" } ?? "none")
        size        \(String(format: "%.1f", Double(Document.inspect(dir).totalBytes) / 1_048_576)) MB
        events      \(events.clicks.count) clicks, \(events.cursor.count) cursor samples
        """)

        if !project.scenes.isEmpty {
            print("\nscenes")
            for s in project.scenes.sorted(by: { $0.at < $1.at }) {
                print("  \(fmt(s.at))s  \(s.layout)")
            }
        }
        if !project.zooms.isEmpty {
            print("\nzooms")
            for z in project.zooms {
                print("  \(fmt(z.start))-\(fmt(z.end))s  x\(fmt(z.level))")
            }
        }
        if !map.isIdentity {
            print("\nsegments")
            for s in project.segments {
                let speed = s.speed > 1.01 ? "  x\(fmt(s.speed))" : ""
                print("  \(fmt(s.sourceStart))-\(fmt(s.sourceEnd))s\(speed)  \(s.note ?? "")")
            }
        }
        if let t = transcript, !t.text.isEmpty {
            print("\ntranscript")
            for s in t.sentences() {
                print("  [\(fmt(s.t))-\(fmt(s.t + s.duration))]  \(s.text)")
            }
        }
        return 0
    }

    static func still(_ args: [String]) async throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        let times = (opts.value("--at") ?? "1.0")
            .split(whereSeparator: { ", ".contains($0) })
            .compactMap { Double($0) }
        guard !times.isEmpty else {
            FileHandle.standardError.write(Data("--at needs at least one time\n".utf8))
            return 1
        }
        let preset = opts.value("--preset").flatMap { ExportPreset.named[$0.lowercased()] }
            ?? ExportPreset.hd
        let base = opts.url("--out") ?? dir.appendingPathComponent("still.png")

        for (i, t) in times.enumerated() {
            let target = times.count == 1 ? base
                : base.deletingPathExtension()
                      .appendingPathExtension("\(i + 1).png")
            try await Still.render(recordingDir: dir, at: t,
                                   outputSize: preset.size, preset: preset, to: target)
            emit(target.path)
        }
        return 0
    }

    /// Screenshot of the whole display. Used for looking at Cutaway's own
    /// window during development, since a shell has no screen-recording grant.
    static func snap(_ args: [String]) async throws -> Int32 {
        let opts = Options(args)
        let out = opts.url("--out")
            ?? URL(fileURLWithPath: NSTemporaryDirectory() + "cutaway-snap.png")
        try await Snapshot.captureDisplay(to: out)
        emit(out.path)
        return 0
    }

    static func pitch(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        guard let m = Manifest.load(from: dir.appendingPathComponent("recording.json")) else {
            FileHandle.standardError.write(Data("no recording in \(dir.path)\n".utf8))
            return 1
        }
        let p = Project.makePitch(recordingDir: dir, manifest: m,
                                  name: opts.value("--name") ?? "Your Name",
                                  role: opts.value("--role") ?? "Engineer")
        try p.write(to: dir)
        Log.line("pitch template: \(p.scenes.count) scenes, \(p.zooms.count) zooms, "
                 + "\(p.callouts.count) callouts")
        emit(dir.appendingPathComponent(Project.filename).path)
        return 0
    }

    static func doctor() async -> Int32 {
        let checks = await Doctor.run()
        var bad = 0
        for c in checks {
            let mark = c.ok ? "ok  " : "FAIL"
            emit("\(mark)  \(c.name.padding(toLength: 20, withPad: " ", startingAt: 0))\(c.detail)")
            if !c.ok { bad += 1 }
        }
        for c in checks where !c.ok {
            if let fix = c.fix {
                emit("")
                emit("\(c.name):")
                for line in fix.split(separator: "\n") {
                    emit("  " + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        emit("")
        emit(bad == 0 ? "everything ready" : "\(bad) item(s) need attention")
        return 0
    }

    static func pack(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        let out = opts.url("--out")
            ?? dir.deletingLastPathComponent()
                  .appendingPathComponent(dir.lastPathComponent)
                  .appendingPathExtension(Document.fileExtension)
        let doc = try Document.wrap(recordingDir: dir,
                                    as: out.deletingPathExtension().lastPathComponent,
                                    in: out.deletingLastPathComponent())
        let c = Document.inspect(doc)
        Log.line(String(format: "packed %.1f MB", Double(c.totalBytes) / 1_048_576))
        emit(doc.path)
        return 0
    }

    static func trim(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        let freed = try Document.discardMedia(in: dir)
        Log.line(String(format: "freed %.1f MB of raw capture", Double(freed) / 1_048_576))
        emit(dir.path)
        return 0
    }

    static func windows() async throws -> Int32 {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        var seen = Set<String>()
        for w in content.windows {
            guard let app = w.owningApplication,
                  case let id = app.bundleIdentifier, !id.isEmpty,
                  w.frame.width > 120, w.frame.height > 80 else { continue }
            guard seen.insert(id).inserted else { continue }
            emit("\(id.padding(toLength: 40, withPad: " ", startingAt: 0))\(app.applicationName)")
        }
        return 0
    }

    static func voices() -> Int32 {
        let all = VoiceoverRenderer.availableVoices()
        for v in all.sorted(by: { ($0.quality, $0.name) > ($1.quality, $1.name) }) {
            print("\(v.quality.padding(toLength: 9, withPad: " ", startingAt: 0))  \(v.name)  \(v.identifier)")
        }
        if !all.contains(where: { $0.quality != "default" }) {
            print("""

            Only default-quality voices are installed, which sound robotic.
            System Settings > Accessibility > Spoken Content > System Voice >
            Manage Voices, then download a Premium voice.
            """)
        }
        return 0
    }

    // MARK: helpers

    static var defaultDir: URL {
        URL(fileURLWithPath: NSString(string: "~/coding/tools/video-editor/tmp/claude/recordings")
            .expandingTildeInPath)
    }

    static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    struct Options {
        private let args: [String]
        init(_ args: [String]) { self.args = args }

        func flag(_ name: String) -> Bool { args.contains(name) }

        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        func double(_ name: String) -> Double? { value(name).flatMap(Double.init) }

        func url(_ name: String) -> URL? {
            value(name).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        }
    }
}
