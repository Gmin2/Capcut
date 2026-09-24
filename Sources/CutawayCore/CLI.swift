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
            case "transcribe": return try await transcribe(args)
            case "pack":     return try pack(args)
            case "trim":     return try trim(args)
            case "recut":    return try recut(args)
            case "shots":    return shots(args)
            case "import":   return try await importVideo(args)
            case "phone":    return try await phone(args)
            case "snippet":  return try await snippet(args)
            case "windows":  return try await windows()
            case "displays": return try await displays()
            case "list":     return list()
            case "voices":   return voices()
            case "icons":
                return await MainActor.run {
                    let out = Options(args).url("--out") ?? URL(fileURLWithPath: "icons.png")
                    Gallery.icons(to: out)
                    emit(out.path)
                    return 0
                }
            case "gallery":
                let o = Options(args)
                let base = o.url("--out") ?? URL(fileURLWithPath: "gallery.png")
                for dark in [false, true] {
                    let url = base.deletingPathExtension()
                        .appendingPathExtension(dark ? "dark.png" : "light.png")
                    try Gallery.render(dark: dark, to: url)
                    emit(url.path)
                }
                return 0
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

    /// Commands that touch the screen, camera or microphone, or that write
    /// into the recordings folder. The folder needs the app's own permission:
    /// run straight from a terminal, the same write is refused.
    static let childMarker = "--cutaway-child"

    static func needsAppLaunch(_ args: [String]) -> Bool {
        ["record", "snap", "doctor", "windows", "displays", "transcribe",
         "export", "still", "pitch", "trim", "recut", "pack", "shots"]
            .contains(args.first ?? "")
            // rendering snippets writes through the same grant as export;
            // editing the list is a plain file write
            || (args.first == "snippet" && args.dropFirst().first == "export")
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

        // Diagnostics stream in before the result, so the wait ends on a line
        // that is not a diagnostic rather than on the first byte written.
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        while Date() < deadline {
            if let t = try? String(contentsOf: outFile, encoding: .utf8), !t.isEmpty {
                let hasResult = t.split(separator: "\n").contains { !$0.hasPrefix("·") }
                if hasResult { text = t; break }
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
    /// Diagnostics from a relaunched child, prefixed so the caller can tell
    /// them apart from the command's actual result.
    static func mirrorLogs() {
        Log.mirrorTo = { line in
            guard let path = outPath, let h = FileHandle(forWritingAtPath: path) else { return }
            h.seekToEndOfFile()
            h.write(Data(("· " + line + "\n").utf8))
            try? h.close()
        }
    }

    public static func takePendingRequest() -> [String]? {
        guard let data = try? Data(contentsOf: pendingURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let args = obj["args"] as? [String] else { return nil }
        outPath = obj["out"] as? String
        mirrorLogs()
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

          record [--seconds N] [--out DIR] [--name NAME] [--no-webcam] [--no-mic]
                 [--system-audio] [--keys] [--countdown N]
                 [--exclude bundle.id,...] [--only bundle.id] [--display ID]
                 [--area X,Y,W,H]
              Records the screen, then writes display.mov, events.json,
              recording.json, transcript.json and a default project.json.
              --keys logs keystrokes for the overlay; needs Input Monitoring.
              --exclude keeps an app's windows out of the capture entirely.
              --only captures just one app instead of the whole display.
              --area records part of the display, in points from its top left.
              Use `cutaway windows` to find bundle ids and `cutaway displays`
              to find display ids.

          shots [--trash NAME]
              Lists captures in ~/Pictures/Cutaway, newest first. --trash moves
              the first one whose name contains NAME to the bin.

          recut [--in DIR] [--none]
              Rebuilds the cut list of a take already recorded. --none keeps
              the whole take. Use it if an export came out far too short.

          export [--in DIR] [--out FILE] [--preset NAME] [--all]
                 [--width N] [--height N] [--fps N] [--codec hevc|h264]
              Renders the edit described by project.json. A custom size with
              a .gif output makes a gif at that size.
              Presets: 1080p, 4k, h264, vertical, square, gif.
              --all writes every preset next to the output file.

          describe [--in DIR] [--json]
              Prints what is in a recording: duration, tracks, clicks, cuts,
              zooms, scenes and the transcript. Start here before editing.

          still --at T[,T2,...] [--in DIR] [--out FILE] [--preset NAME]
                [--width N] [--height N]
              Renders composited frames to PNG. Much faster than an export
              when checking a layout or an overlay. Without a preset or a
              size it uses the output size in project.json.

          pitch --name "Your Name" --role "Your Role" [--in DIR]
              Rewrites project.json as a pitch video: webcam opening, handover
              to the screen, lower third, auto zooms, device frame.

          transcribe [--in DIR] [--audio FILE]
              Transcribes the narration and writes transcript.json. Runs
              automatically after recording with a microphone; use this to
              redo it, or to caption a synthesised voiceover.

          doctor
              Checks every permission and dependency, and says how to fix
              whatever is missing. Start here when something silently does
              nothing.

          pack [--in DIR] [--out FILE.cutaway]
              Wraps a recording into a single .cutaway document.

          trim [--in DIR]
              Deletes the raw capture, keeping the edit and the event log.
              Do this once an export is approved; raw media is most of the size.

          import --video FILE [--out DIR] [--name NAME]
              Makes a recording out of a video file that did not come from
              Cutaway, like a phone screen recording, so it can be framed,
              cut and exported like any other take.

          phone record [--device android|iphone] [--serial ID] [--seconds N]
                       [--name NAME] [--out DIR] [--keep-status-bar]
              Records the android emulator or the iphone simulator: the screen
              at its own resolution, every tap, and a clean 9:41 status bar.
              Press return to start a snippet and return again to end it;
              q then return, or ctrl-c, stops. The simulator needs
              Window > Show Device Bezels off for taps to be tracked.

          phone devices
              Lists running emulators and booted simulators.

          phone status-bar on|off [--device android|iphone] [--serial ID]
              Sets or clears the clean status bar by hand, for screenshots.

          snippet add --name NAME --from S --to S [--in DIR]
                      [--look framed|bare] [--canvas feed|story|square]
                      [--background PRESET] [--loop crossfade|none]
              Adds a snippet, or changes the one with that name. Times are
              source seconds. framed puts the phone on a background, bare is
              the screen alone.

          snippet list [--in DIR]
          snippet remove --name NAME [--in DIR]

          snippet export [--in DIR] [--name NAME] [--out DIR] [--gif]
              Renders every snippet, or just one, as NAME.mp4 plus a poster
              NAME.png (and NAME.gif), into DIR/snippets unless --out says.

          snap [--out FILE]
              Screenshots the display through the app's capture grant.

          windows
              Lists open windows and their bundle ids, for --exclude and --only.

          displays
              Lists displays and their ids, for --display.

          list
              Lists recordings, newest first.

          voices
              Lists installed speech voices for project.json voiceover.

        Editing is done by rewriting project.json. Times are seconds in source
        time; the app hot-reloads the file if it is open.
        """)
    }

    // MARK: commands

    static func record(_ args: [String]) async throws -> Int32 {
        let opts = Options(args)
        // Each take gets its own dated folder; Latest points at the newest so
        // commands with no --in keep working.
        let dir = opts.url("--out") ?? Paths.newRecording(named: opts.value("--name"))
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
        r.displayID = opts.double("--display").map { CGDirectDisplayID($0) }
        if let a = opts.value("--area")?.split(separator: ",").compactMap({ Double($0) }), a.count == 4 {
            r.area = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }

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
        // a take written somewhere else on purpose should not become Latest
        if dir.standardizedFileURL.path.hasPrefix(Paths.recordingsRoot.standardizedFileURL.path) {
            Paths.linkLatest(to: dir)
        }
        emit(dir.path)
        return 0
    }

    /// Rebuilds the cut list of a take that was already recorded, for one cut
    /// badly by an older version.
    static func recut(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        guard var p = Project.load(from: dir),
              let m = Manifest.load(from: dir.appendingPathComponent("recording.json")) else {
            Log.line("no take at \(dir.path)")
            return 1
        }
        let before = p.segments.count
        if opts.flag("--none") {
            p.segments = []
        } else {
            let ev = Events.load(from: dir)
            let transcript = Transcript.load(from: dir)
            p.segments = transcript != nil || !ev.clicks.isEmpty
                ? AutoCut.segments(events: ev, transcript: transcript, duration: m.screen.duration)
                : []
        }
        try p.write(to: dir)
        let kept = p.segments.reduce(0.0) { $0 + ($1.sourceEnd - $1.sourceStart) }
        emit("recut: \(before) -> \(p.segments.count) segments, "
             + String(format: "%.1fs of %.1fs kept", p.segments.isEmpty ? m.screen.duration : kept,
                      m.screen.duration))
        return 0
    }

    /// Captures on disk, and a way to bin one without opening the app.
    static func shots(_ args: [String]) -> Int32 {
        let opts = Options(args)
        let all = CaptureHistory.allShots()
        if let name = opts.value("--trash") {
            guard let match = all.first(where: { $0.lastPathComponent.contains(name) }) else {
                emit("no capture matching \(name)")
                return 1
            }
            do {
                try FileManager.default.trashItem(at: match, resultingItemURL: nil)
                emit("binned \(match.lastPathComponent)")
                return 0
            } catch {
                emit("could not bin it: \(error.localizedDescription)")
                return 1
            }
        }
        if all.isEmpty {
            emit("no captures yet")
            return 0
        }
        for url in all {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            emit("\(url.lastPathComponent)  \(size / 1024) KB")
        }
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
        // HEVC is smaller, but feeds and older players still want H.264, and
        // H.264 needs more bits to look the same.
        if opts.value("--codec")?.lowercased() == "h264" {
            preset.codec = .h264
            preset.bitrate = Int(Double(preset.bitrate) * 1.6)
        }
        // A custom size written to .gif means a gif at that size, which is how
        // a portrait loop for a feed gets made.
        if out.pathExtension.lowercased() == "gif" { preset.isGIF = true }

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
        // A preset wins, then an explicit size, then the size the project asks
        // for, so a still matches what an export of that project would look like.
        var preset = opts.value("--preset").flatMap { ExportPreset.named[$0.lowercased()] }
        if preset == nil {
            let output = Project.load(from: dir)?.output ?? Project.Output()
            preset = ExportPreset(
                name: "custom",
                size: CGSize(width: opts.double("--width") ?? output.width,
                             height: opts.double("--height") ?? output.height),
                fps: Int32(output.fps), codec: .hevc, bitrate: 12_000_000)
        }
        guard let preset else { return 1 }
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

    static func transcribe(_ args: [String]) async throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        let manifest = Manifest.load(from: dir.appendingPathComponent("recording.json"))

        // Prefer the real voice; fall back to synthesised narration, which is
        // what you caption when the video is narrated rather than spoken.
        let audio = opts.url("--audio")
            ?? manifest?.mic.map { dir.appendingPathComponent($0.file) }
            ?? [dir.appendingPathComponent("voiceover.m4a"),
                dir.appendingPathComponent("mix.m4a")]
                .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let audio else {
            FileHandle.standardError.write(Data("no audio to transcribe in \(dir.path)\n".utf8))
            return 1
        }
        let offset = manifest?.mic?.offset ?? 0
        let t = try await Transcriber.run(audio: audio, offset: offset)
        try t.write(to: dir)
        emit(dir.appendingPathComponent("transcript.json").path)
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

    static func importVideo(_ args: [String]) async throws -> Int32 {
        let opts = Options(args)
        guard let video = opts.url("--video") else {
            FileHandle.standardError.write(Data("import needs --video FILE\n".utf8))
            return 1
        }
        let fm = FileManager.default
        let dir = opts.url("--out") ?? Paths.newRecording(named: opts.value("--name"))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = video.pathExtension.isEmpty ? "mov" : video.pathExtension.lowercased()
        let file = "display.\(ext)"
        let dest = dir.appendingPathComponent(file)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: video, to: dest)

        let asset = AVURLAsset(url: dest)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            FileHandle.standardError.write(Data("no video track in \(video.lastPathComponent)\n".utf8))
            return 1
        }
        // A phone recording can carry its orientation as a transform rather
        // than in its pixels, so size it the way it plays.
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let shown = natural.applying(transform)
        let size = CGSize(width: abs(shown.width), height: abs(shown.height))
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let rate = Double(try await track.load(.nominalFrameRate))

        let manifest = Manifest(screen: .init(
            file: file, pixelSize: [Double(size.width), Double(size.height)],
            offset: 0, duration: duration, frames: Int((rate * duration).rounded())))
        try manifest.write(to: dir.appendingPathComponent("recording.json"))

        if !Project.exists(in: dir) {
            // No pointer and no voice in an imported video, so the automatic
            // cuts and zooms would be guessing. Start from the whole clip.
            var project = Project.makeDefault(recordingDir: dir, manifest: manifest)
            project.segments = []
            project.zooms = []
            project.cursor.visible = false
            project.output = .init(width: Double(size.width), height: Double(size.height), fps: max(Int(rate.rounded()), 30))
            try project.write(to: dir)
        }
        Log.line(String(format: "imported %.0fx%.0f, %.1fs", size.width, size.height, duration))
        emit(dir.path)
        return 0
    }

    static func phone(_ args: [String]) async throws -> Int32 {
        var args = args
        let sub = args.isEmpty ? "record" : args.removeFirst()
        let opts = Options(args)
        let kind = PhoneKind(rawValue: opts.value("--device")?.lowercased() ?? "android") ?? .android

        switch sub {
        case "devices":
            let droids = (try? Android.devices()) ?? []
            let sims = (try? Simulator.booted()) ?? []
            if droids.isEmpty && sims.isEmpty { emit("no emulator or simulator running") }
            for d in droids { emit("android  \(d)") }
            for s in sims { emit("iphone   \(s.udid)  \(s.name)") }
            return 0

        case "status-bar":
            let on = args.first != "off"
            switch kind {
            case .android: try Android.cleanStatusBar(on, serial: try Android.pick(opts.value("--serial")))
            case .iphone: try Simulator.cleanStatusBar(on, udid: try Simulator.pick(opts.value("--serial")).udid)
            }
            emit("status bar \(on ? "clean" : "restored")")
            return 0

        case "record":
            let dir = opts.url("--out") ?? Paths.newRecording(named: opts.value("--name"))
            let r = PhoneRecorder(kind: kind, dir: dir)
            r.cleanStatusBar = !opts.flag("--keep-status-bar")
            try r.start(device: opts.value("--serial"))

            let stop = DispatchSemaphore(value: 0)
            if let seconds = opts.double("--seconds") {
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { stop.signal() }
            } else {
                emit("recording \(r.deviceName). return starts a snippet, return again ends it. "
                     + "q then return, or ctrl-c, stops.")
            }
            signal(SIGINT, SIG_IGN)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            sigint.setEventHandler { stop.signal() }
            sigint.resume()
            if opts.double("--seconds") == nil {
                Thread.detachNewThread {
                    // end of input is not a stop: with no terminal attached
                    // it comes at once, and the take would be over before it
                    // began. ctrl-c still works.
                    while let line = readLine() {
                        if line.trimmingCharacters(in: .whitespaces).lowercased() == "q" {
                            stop.signal()
                            return
                        }
                        let opened = r.mark()
                        emit(String(format: "%@ snippet at %.1fs", opened ? "start" : "end  ", r.elapsed))
                    }
                }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { stop.wait(); c.resume() }
            }
            sigint.cancel()
            signal(SIGINT, SIG_DFL)
            emit("stopping, joining the video")
            let out = try await r.stop()
            if out.standardizedFileURL.path.hasPrefix(Paths.recordingsRoot.standardizedFileURL.path) {
                Paths.linkLatest(to: out)
            }
            emit(out.path)
            return 0

        default:
            FileHandle.standardError.write(Data("unknown phone command: \(sub)\n".utf8))
            return 1
        }
    }

    static func snippet(_ args: [String]) async throws -> Int32 {
        var args = args
        let sub = args.isEmpty ? "list" : args.removeFirst()
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        guard var p = Project.load(from: dir) else {
            FileHandle.standardError.write(Data("no project.json in \(dir.path)\n".utf8))
            return 1
        }

        switch sub {
        case "list":
            if p.snippets.isEmpty { emit("no snippets. add one with: cutaway snippet add --name NAME --from S --to S") }
            for s in p.snippets {
                emit(String(format: "%@  %6.2f-%6.2fs  %@ %@ %@ %@",
                            s.name.padding(toLength: 20, withPad: " ", startingAt: 0),
                            s.start, s.end, s.look.rawValue, s.canvas.rawValue,
                            s.background ?? "dusk", s.loop.rawValue))
            }
            return 0

        case "add":
            guard let name = opts.value("--name") else {
                FileHandle.standardError.write(Data("snippet add needs --name\n".utf8))
                return 1
            }
            var s = p.snippets.first { $0.name == name }
                ?? Snippet(name: name, start: 0, end: 0)
            if let v = opts.double("--from") { s.start = v }
            if let v = opts.double("--to") { s.end = v }
            if let v = opts.value("--look") {
                guard let look = Snippet.Look(rawValue: v) else {
                    FileHandle.standardError.write(Data("--look is framed or bare\n".utf8))
                    return 1
                }
                s.look = look
            }
            if let v = opts.value("--canvas") {
                guard let c = Snippet.Canvas(rawValue: v) else {
                    FileHandle.standardError.write(Data("--canvas is feed, story or square\n".utf8))
                    return 1
                }
                s.canvas = c
            }
            if let v = opts.value("--background") {
                guard Style.presets[v] != nil else {
                    FileHandle.standardError.write(Data(
                        "no background \(v). try: \(Style.presets.keys.sorted().joined(separator: ", "))\n".utf8))
                    return 1
                }
                s.background = v
            }
            if let v = opts.value("--loop") { s.loop = Snippet.Loop(rawValue: v) ?? .crossfade }
            guard s.end > s.start else {
                FileHandle.standardError.write(Data("snippet \(name) needs --from before --to\n".utf8))
                return 1
            }
            if let i = p.snippets.firstIndex(where: { $0.name == name }) {
                p.snippets[i] = s
            } else {
                p.snippets.append(s)
            }
            try p.write(to: dir)
            emit(String(format: "%@  %.2f-%.2fs", s.name, s.start, s.end))
            return 0

        case "remove":
            guard let name = opts.value("--name"),
                  let i = p.snippets.firstIndex(where: { $0.name == name }) else {
                FileHandle.standardError.write(Data("no snippet with that --name\n".utf8))
                return 1
            }
            p.snippets.remove(at: i)
            try p.write(to: dir)
            emit("removed \(name)")
            return 0

        case "export":
            let chosen = opts.value("--name").map { n in p.snippets.filter { $0.name == n } } ?? p.snippets
            guard !chosen.isEmpty else {
                FileHandle.standardError.write(Data("no snippets to export\n".utf8))
                return 1
            }
            let out = opts.url("--out") ?? dir.appendingPathComponent("snippets")
            var written: [String] = []
            for s in chosen {
                let r = try await SnippetExport.run(recordingDir: dir, snippet: s, outDir: out,
                                                    gif: opts.flag("--gif"))
                written.append(r.video.path)
                if let g = r.gif { written.append(g.path) }
            }
            // one emit: a relaunched child is read until its first result
            // line, so paths written one by one would cut the wait short
            emit(written.joined(separator: "\n"))
            return 0

        default:
            FileHandle.standardError.write(Data("unknown snippet command: \(sub)\n".utf8))
            return 1
        }
    }

    static func trim(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        let dir = opts.url("--in") ?? defaultDir
        let freed = try Document.discardMedia(in: dir)
        Log.line(String(format: "freed %.1f MB of raw capture", Double(freed) / 1_048_576))
        emit(dir.path)
        return 0
    }

    static func list() -> Int32 {
        let all = Paths.allRecordings()
        guard !all.isEmpty else {
            emit("no recordings in \(Paths.recordingsRoot.path)")
            return 0
        }
        for url in all {
            let m = Manifest.load(from: url.appendingPathComponent("recording.json"))
            let size = Double(Document.inspect(url).totalBytes) / 1_048_576
            emit(String(format: "%@  %5.1fs  %6.1f MB",
                        url.lastPathComponent.padding(toLength: 26, withPad: " ",
                                                      startingAt: 0),
                        m?.screen.duration ?? 0, size))
        }
        return 0
    }

    static func displays() async throws -> Int32 {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let main = CGMainDisplayID()
        for d in content.displays {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID
            }
            let scale = screen?.backingScaleFactor ?? 2
            let name = screen?.localizedName ?? "display"
            let tag = d.displayID == main ? "  (main)" : ""
            emit("\(String(d.displayID).padding(toLength: 12, withPad: " ", startingAt: 0))"
                 + "\(Int(CGFloat(d.width) * scale))x\(Int(CGFloat(d.height) * scale))"
                 + "  \(name)\(tag)")
        }
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
        Paths.currentRecording
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
