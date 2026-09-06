import Foundation
import AppKit
import AVFoundation

/// Headless entry points.
///
/// The point of this file is that everything Cutaway does is scriptable: an
/// agent can record, inspect what happened, rewrite the edit and export, all
/// without a window. It is the same code the UI calls, so the two cannot drift.
public enum CLI {

    public static func run(_ args: [String]) async -> Int32 {
        var args = args
        let command = args.isEmpty ? "help" : args.removeFirst()

        do {
            switch command {
            case "record":   return try await record(args)
            case "export":   return try await export(args)
            case "describe": return try describe(args)
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
    static func needsAppLaunch(_ args: [String]) -> Bool {
        args.first == "record"
    }

    /// Runs this same bundle via `open`, waits, and forwards its output.
    static func relaunchThroughBundle(_ args: [String]) -> Int32 {
        let bundle = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // Cutaway.app

        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutaway-cli-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-W", "-n", "-a", bundle.path, "--args"] + args
        var env = ProcessInfo.processInfo.environment
        env["CUTAWAY_CHILD"] = "1"
        env["CUTAWAY_CLI_OUT"] = outFile.path
        p.environment = env

        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            FileHandle.standardError.write(Data("relaunch failed: \(error)\n".utf8))
            return 1
        }

        if let text = try? String(contentsOf: outFile, encoding: .utf8), !text.isEmpty {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        try? FileManager.default.removeItem(at: outFile)
        return p.terminationStatus
    }

    /// stdout is a pipe file when running as a relaunched child, since a
    /// process started by `open` has no terminal attached.
    static func emit(_ s: String) {
        if let path = ProcessInfo.processInfo.environment["CUTAWAY_CLI_OUT"],
           let handle = FileHandle(forWritingAtPath: path) {
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
                 [--system-audio] [--keys]
              Records the screen, then writes display.mov, events.json,
              recording.json, transcript.json and a default project.json.
              --keys logs keystrokes for the overlay; needs Input Monitoring.

          export [--in DIR] [--out FILE] [--preset NAME] [--all]
                 [--width N] [--height N] [--fps N]
              Renders the edit described by project.json.
              Presets: 1080p, 4k, h264, vertical, square, gif.
              --all writes every preset next to the output file.

          describe [--in DIR] [--json]
              Prints what is in a recording: duration, tracks, clicks, cuts,
              zooms, scenes and the transcript. Start here before editing.

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
