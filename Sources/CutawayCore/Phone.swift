import Foundation
import AppKit
import AVFoundation

/// Where a phone take comes from. Both are virtual devices on this mac, so
/// nothing from a real phone (its notifications, its clock, its carrier) can
/// end up in the shot.
public enum PhoneKind: String, CaseIterable {
    case android, iphone
}

/// Runs a tool and hands back what it printed.
enum Shell {
    @discardableResult
    static func run(_ tool: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "cutaway", code: 130, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(tool.lastPathComponent) \(args.prefix(3).joined(separator: " ")) failed: "
                    + text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)])
        }
        return text
    }

    /// What a tool wrote to stdout, as bytes, for images.
    static func data(_ tool: URL, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    /// Starts a tool and calls back with each line it prints, on a
    /// background thread, along with the mac time the line arrived.
    static func stream(_ tool: URL, _ args: [String],
                       onLine: @escaping (String, Double) -> Void) throws -> Process {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        // adb forwards stdin to the device; left attached it would eat the
        // returns meant for marking snippets
        p.standardInput = FileHandle.nullDevice
        var pending = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else {
                h.readabilityHandler = nil
                return
            }
            let now = Date().timeIntervalSince1970
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                onLine(line.trimmingCharacters(in: .whitespacesAndNewlines), now)
            }
        }
        try p.run()
        return p
    }
}

/// The android side: the emulator, or any device adb can see.
public enum Android {

    public static var adb: URL? {
        let env = ProcessInfo.processInfo.environment
        var roots: [String] = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }
        roots.append(NSString(string: "~/Library/Android/sdk").expandingTildeInPath)
        var candidates: [String] = roots.map { $0 + "/platform-tools/adb" }
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func tool() throws -> URL {
        guard let adb else {
            throw NSError(domain: "cutaway", code: 131, userInfo: [
                NSLocalizedDescriptionKey:
                    "adb not found. install android studio, or set ANDROID_HOME"])
        }
        return adb
    }

    /// Serials of devices that are up, emulators first since that is what a
    /// clean take is recorded on.
    public static func devices() throws -> [String] {
        let text = try Shell.run(tool(), ["devices"])
        var emulators: [String] = []
        var phones: [String] = []
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count == 2, cols[1] == "device" else { continue }
            if cols[0].hasPrefix("emulator-") { emulators.append(cols[0]) } else { phones.append(cols[0]) }
        }
        return emulators + phones
    }

    public static func pick(_ serial: String?) throws -> String {
        let all = try devices()
        if let serial {
            guard all.contains(serial) else {
                throw NSError(domain: "cutaway", code: 132, userInfo: [
                    NSLocalizedDescriptionKey: "no android device \(serial). running: \(all.joined(separator: ", "))"])
            }
            return serial
        }
        guard let first = all.first else {
            throw NSError(domain: "cutaway", code: 133, userInfo: [
                NSLocalizedDescriptionKey: "no android emulator running. start one from android studio"])
        }
        return first
    }

    static func shell(_ serial: String, _ args: [String]) throws -> String {
        try Shell.run(tool(), ["-s", serial, "shell"] + args)
    }

    /// The size screenrecord will record at: an override if one is set,
    /// otherwise the panel.
    public static func screenSize(_ serial: String) throws -> CGSize {
        let text = try shell(serial, ["wm", "size"])
        var size = CGSize.zero
        for line in text.split(separator: "\n") {
            guard let dims = line.split(separator: ":").last?
                    .trimmingCharacters(in: .whitespaces).split(separator: "x"),
                  dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]) else { continue }
            size = CGSize(width: w, height: h)   // the override comes last
        }
        return size
    }

    /// Android's demo mode: 9:41, full battery, full wifi, nothing in the
    /// notification area. Off puts the real status bar back.
    public static func cleanStatusBar(_ on: Bool, serial: String) throws {
        func demo(_ extra: [String]) throws {
            _ = try shell(serial, ["am", "broadcast", "-a", "com.android.systemui.demo",
                                   "-e", "command"] + extra)
        }
        guard on else {
            try demo(["exit"])
            return
        }
        _ = try shell(serial, ["settings", "put", "global", "sysui_demo_allowed", "1"])
        try demo(["enter"])
        try demo(["clock", "-e", "hhmm", "0941"])
        try demo(["battery", "-e", "level", "100", "-e", "plugged", "false"])
        try demo(["network", "-e", "wifi", "show", "-e", "level", "4", "-e", "fully", "true"])
        // mobile data draws a "3G" or "LTE" tag next to the bars, which dates
        // the shot, so only wifi shows
        try demo(["network", "-e", "mobile", "hide"])
        try demo(["notifications", "-e", "visible", "false"])
    }
}

/// The iphone side: Xcode's simulator.
public enum Simulator {

    public struct Device {
        public var udid: String
        public var name: String
    }

    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    public static func booted() throws -> [Device] {
        let text = try Shell.run(xcrun, ["simctl", "list", "devices", "booted", "-j"])
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let runtimes = obj["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.values.flatMap { $0 }.compactMap { d in
            guard (d["state"] as? String) == "Booted",
                  let udid = d["udid"] as? String, let name = d["name"] as? String else { return nil }
            return Device(udid: udid, name: name)
        }
    }

    public static func pick(_ udid: String?) throws -> Device {
        let all = try booted()
        if let udid {
            guard let d = all.first(where: { $0.udid == udid || $0.name == udid }) else {
                throw NSError(domain: "cutaway", code: 134, userInfo: [
                    NSLocalizedDescriptionKey: "no booted simulator \(udid)"])
            }
            return d
        }
        guard let first = all.first else {
            throw NSError(domain: "cutaway", code: 135, userInfo: [
                NSLocalizedDescriptionKey:
                    "no iphone simulator running. open Simulator, or: xcrun simctl boot \"iPhone 17 Pro\""])
        }
        return first
    }

    /// Takes a screenshot to learn the screen size, since simctl has no
    /// command that just says it.
    public static func screenSize(_ udid: String) throws -> CGSize {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutaway-sim-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try Shell.run(xcrun, ["simctl", "io", udid, "screenshot", tmp.path])
        guard let img = NSImage(contentsOf: tmp),
              let rep = img.representations.first else { return .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    public static func cleanStatusBar(_ on: Bool, udid: String) throws {
        guard on else {
            _ = try Shell.run(xcrun, ["simctl", "status_bar", udid, "clear"])
            return
        }
        // discharging at 100: "charged" draws a bolt on the battery
        _ = try Shell.run(xcrun, [
            "simctl", "status_bar", udid, "override", "--time", "9:41",
            "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
            "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
            "--batteryState", "discharging", "--batteryLevel", "100"])
    }

    /// On screen Simulator windows, in global display points from the top
    /// left. Bounds and owner need no screen recording grant.
    static func windows() -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Simulator",
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 100, height > 100 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}

/// A running phone, as the record screen lists it.
public struct PhoneDevice: Equatable {
    public var kind: PhoneKind
    public var id: String
    public var name: String

    /// kind:id, which is what the record settings keep.
    public var key: String { "\(kind.rawValue):\(id)" }

    public init(kind: PhoneKind, id: String, name: String) {
        self.kind = kind
        self.id = id
        self.name = name
    }

    public init?(key: String) {
        guard let colon = key.firstIndex(of: ":"),
              let kind = PhoneKind(rawValue: String(key[..<colon])) else { return nil }
        self.init(kind: kind, id: String(key[key.index(after: colon)...]), name: "")
    }

    public static func running() -> [PhoneDevice] {
        let droids = ((try? Android.devices()) ?? []).map {
            PhoneDevice(kind: .android, id: $0,
                        name: $0.hasPrefix("emulator-") ? "Android emulator" : "Android \($0)")
        }
        let sims = ((try? Simulator.booted()) ?? []).map {
            PhoneDevice(kind: .iphone, id: $0.udid, name: $0.name)
        }
        return droids + sims
    }

    /// What is on its screen right now.
    public func screenshot() -> CGImage? {
        var png: Data?
        switch kind {
        case .android:
            guard let adb = Android.adb else { return nil }
            png = Shell.data(adb, ["-s", id, "exec-out", "screencap", "-p"])
        case .iphone:
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("cutaway-shot-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? Shell.run(Simulator.xcrun, ["simctl", "io", id, "screenshot", tmp.path])) != nil
            else { return nil }
            png = try? Data(contentsOf: tmp)
        }
        guard let png, let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Records one take off a virtual phone: the screen at its own resolution,
/// every tap, and snippet ranges marked while recording. Writes an ordinary
/// take folder, so the editor and every export work on it unchanged.
public final class PhoneRecorder: @unchecked Sendable {

    public let kind: PhoneKind
    public var cleanStatusBar = true

    private let dir: URL
    private var serial = ""
    private var sim: Simulator.Device?
    private(set) public var screen = CGSize.zero

    private let lock = NSLock()
    private var chunks: [ChunkClock.Chunk] = []
    private var chunkFiles: [String] = []
    private var chunkStart: Double?
    private var stopping = false
    private var recorder: Process?
    private let loopDone = DispatchSemaphore(value: 0)

    private var parser: GetEventParser?
    private var getevent: Process?
    private var deviceTaps: [Tap] = []
    private var hostTaps: [Tap] = []
    private var mouseTimer: DispatchSourceTimer?
    private var mouseWasDown = false
    private var warnedBezel = false

    private var marks: [Double] = []
    private var startedAt = 0.0

    public init(kind: PhoneKind, dir: URL) {
        self.kind = kind
        self.dir = dir
    }

    /// The device picked for this take, for the log.
    public var deviceName: String {
        kind == .android ? serial : (sim?.name ?? "")
    }

    public func start(device: String? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        startedAt = Date().timeIntervalSince1970
        switch kind {
        case .android:
            serial = try Android.pick(device)
            screen = try Android.screenSize(serial)
            if cleanStatusBar { try Android.cleanStatusBar(true, serial: serial) }
            try startTouchLog()
            startAndroidLoop()
        case .iphone:
            let d = try Simulator.pick(device)
            sim = d
            screen = try Simulator.screenSize(d.udid)
            if cleanStatusBar { try Simulator.cleanStatusBar(true, udid: d.udid) }
            try startSimulatorRecording(d)
            startMouseLog()
        }
        Log.line("phone: recording \(kind.rawValue) \(deviceName) at \(Int(screen.width))x\(Int(screen.height))")
    }

    /// Seconds into the take so far, on the video's timeline.
    public var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        return clock(now: Date().timeIntervalSince1970).duration
    }

    /// Starts a snippet, or ends the one that is open. Returns true when
    /// this opened one.
    @discardableResult
    public func mark() -> Bool {
        let t = elapsed
        lock.lock(); defer { lock.unlock() }
        marks.append(t)
        return marks.count % 2 == 1
    }

    public func stop() async throws -> URL {
        let take = try halt()
        return try await finish(take)
    }

    /// What a finished recording left behind, read out under the lock.
    struct Take {
        var clock: ChunkClock
        var files: [String]
        var taps: [Tap]
        var marks: [Double]
    }

    private func halt() throws -> Take {
        lock.lock()
        stopping = true
        let stopAt = Date().timeIntervalSince1970
        lock.unlock()
        mouseTimer?.cancel()
        mouseTimer = nil

        switch kind {
        case .android:
            // SIGINT lets screenrecord finish the file; killing adb would
            // leave it recording on the device with no moov atom.
            _ = try? Android.shell(serial, ["pkill", "-2", "screenrecord"])
            _ = loopDone.wait(timeout: .now() + 15)
            getevent?.terminate()
            if cleanStatusBar { try? Android.cleanStatusBar(false, serial: serial) }
            try pullChunks()
        case .iphone:
            recorder?.interrupt()
            recorder?.waitUntilExit()
            lock.lock()
            if let s = chunkStart { chunks.append(.init(start: s, end: stopAt)) }
            chunkStart = nil
            lock.unlock()
            if cleanStatusBar, let sim { try? Simulator.cleanStatusBar(false, udid: sim.udid) }
        }

        lock.lock()
        defer { lock.unlock() }
        // device taps carry the device's clock; move them onto the mac's
        let offset = parser?.clockOffset ?? 0
        let taps = deviceTaps.map { Tap(t: $0.t + offset, x: $0.x, y: $0.y) } + hostTaps
        return Take(clock: ChunkClock(chunks: chunks), files: chunkFiles,
                    taps: taps.sorted { $0.t < $1.t }, marks: marks)
    }

    // MARK: android

    private func startAndroidLoop() {
        let t = Thread { [weak self] in
            guard let self else { return }
            var n = 0
            while true {
                self.lock.lock()
                let done = self.stopping
                self.lock.unlock()
                if done { break }
                let remote = "/sdcard/cutaway-\(n).mp4"
                let proc: Process
                do {
                    // 180 is screenrecord's own ceiling; a longer take chains
                    // files and they are joined afterwards
                    proc = try Shell.stream(try Android.tool(), [
                        "-s", self.serial, "shell", "screenrecord", "--verbose",
                        "--bit-rate", "20000000", "--time-limit", "180", remote,
                    ]) { line, at in
                        // the first frame goes out right after this line
                        if line.hasPrefix("Content area") {
                            self.lock.lock()
                            self.chunkStart = at
                            self.lock.unlock()
                        }
                    }
                } catch {
                    Log.line("phone: screenrecord failed: \(error.localizedDescription)")
                    break
                }
                self.lock.lock()
                self.recorder = proc
                self.lock.unlock()
                proc.waitUntilExit()
                let end = Date().timeIntervalSince1970
                self.lock.lock()
                if let s = self.chunkStart {
                    self.chunks.append(.init(start: s, end: end))
                    self.chunkFiles.append(remote)
                }
                self.chunkStart = nil
                self.lock.unlock()
                n += 1
            }
            self.loopDone.signal()
        }
        t.start()
    }

    private func startTouchLog() throws {
        let caps = try Android.shell(serial, ["getevent", "-pl"])
        parser = GetEventParser(screen: screen, axes: GetEventParser.axes(fromCapabilities: caps))
        getevent = try Shell.stream(try Android.tool(), ["-s", serial, "shell", "getevent", "-lt"]) {
            [weak self] line, at in
            guard let self else { return }
            self.lock.lock()
            if let tap = self.parser?.feed(line, received: at) { self.deviceTaps.append(tap) }
            self.lock.unlock()
        }
    }

    private func pullChunks() throws {
        let adb = try Android.tool()
        lock.lock()
        let remotes = chunkFiles
        lock.unlock()
        var local: [String] = []
        for (i, remote) in remotes.enumerated() {
            let name = "chunk-\(i).mp4"
            _ = try Shell.run(adb, ["-s", serial, "pull", remote, dir.appendingPathComponent(name).path])
            _ = try? Android.shell(serial, ["rm", remote])
            local.append(name)
        }
        lock.lock()
        chunkFiles = local
        lock.unlock()
    }

    // MARK: iphone

    private func startSimulatorRecording(_ d: Simulator.Device) throws {
        let file = dir.appendingPathComponent("chunk-0.mov")
        recorder = try Shell.stream(Simulator.xcrun, [
            "simctl", "io", d.udid, "recordVideo", "--codec", "h264", "--force", file.path,
        ]) { [weak self] line, at in
            guard let self, line.hasPrefix("Recording started") else { return }
            self.lock.lock()
            self.chunkStart = at
            self.lock.unlock()
        }
        // recordVideo takes a moment to get going; taps before it count for
        // nothing, so wait for the line that says it has
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            lock.lock()
            let ok = chunkStart != nil
            lock.unlock()
            if ok { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        chunkFiles = ["chunk-0.mov"]
    }

    /// The simulator reports no touches, so the mouse is watched instead:
    /// a press over a Simulator window is a tap at that spot on the screen.
    /// Polled rather than monitored, which needs no permission and no event
    /// loop.
    private func startMouseLog() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(8))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let isDown = NSEvent.pressedMouseButtons & 1 == 1
            defer { self.mouseWasDown = isDown }
            guard isDown, !self.mouseWasDown else { return }
            let now = Date().timeIntervalSince1970
            let m = NSEvent.mouseLocation
            // AppKit counts up from the bottom of the main display, window
            // bounds count down from its top
            let top = CGDisplayBounds(CGMainDisplayID()).height
            let p = CGPoint(x: m.x, y: top - m.y)
            for bounds in Simulator.windows() where bounds.contains(p) {
                let w = SimulatorWindow(bounds: bounds, screen: self.screen)
                if !w.isBareScreen, !self.warnedBezel {
                    self.warnedBezel = true
                    Log.line("phone: turn off Window > Show Device Bezels in Simulator, taps are not tracked with it on")
                }
                if let px = w.pixel(for: p) {
                    self.lock.lock()
                    self.hostTaps.append(Tap(t: now, x: px.x, y: px.y))
                    self.lock.unlock()
                }
                break
            }
        }
        t.resume()
        mouseTimer = t
    }

    // MARK: finishing

    private func clock(now: Double) -> ChunkClock {
        var all = chunks
        if let s = chunkStart { all.append(.init(start: s, end: now)) }
        return ChunkClock(chunks: all)
    }

    /// Joins the chunks into one constant 60fps file as long as the take
    /// really was. screenrecord and the simulator only write a frame when
    /// the screen changes, so a still ending would otherwise be cut short
    /// and every tap after it would land late.
    private func finish(_ take: Take) async throws -> URL {
        let clock = take.clock
        let files = take.files
        guard !files.isEmpty, clock.duration > 0.1 else {
            throw NSError(domain: "cutaway", code: 136, userInfo: [
                NSLocalizedDescriptionKey: "nothing was recorded"])
        }
        guard let ffmpeg = GIFEncoder.locateFFmpeg() else {
            throw NSError(domain: "cutaway", code: 137, userInfo: [
                NSLocalizedDescriptionKey: "phone takes need ffmpeg (brew install ffmpeg)"])
        }

        let out = dir.appendingPathComponent("display.mp4")
        var args = ["-v", "error", "-y"]
        var graph = ""
        for (i, f) in files.enumerated() {
            args += ["-i", dir.appendingPathComponent(f).path]
            let d = String(format: "%.3f", clock.chunks[i].duration)
            graph += "[\(i):v]setpts=PTS-STARTPTS,fps=60,"
                + "tpad=stop_mode=clone:stop_duration=\(d),trim=duration=\(d),"
                + "setpts=PTS-STARTPTS,format=yuv420p[v\(i)];"
        }
        graph += (0..<files.count).map { "[v\($0)]" }.joined()
            + "concat=n=\(files.count):v=1:a=0[out]"
        args += ["-filter_complex", graph, "-map", "[out]",
                 "-c:v", "libx264", "-crf", "14", "-preset", "fast",
                 "-movflags", "+faststart", out.path]
        try GIFEncoder.run(ffmpeg, args)
        for f in files { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }

        // taps onto the video's timeline
        var clicks: [EventRecorder.Click] = []
        for tap in take.taps {
            guard let t = clock.videoTime(forHost: tap.t) else { continue }
            clicks.append(.init(t: t, x: tap.x, y: tap.y, button: "left", clickCount: 1))
        }

        let asset = AVURLAsset(url: out)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let manifest = Manifest(screen: .init(
            file: "display.mp4", pixelSize: [screen.width, screen.height],
            offset: 0, duration: duration, frames: Int((duration * 60).rounded())))
        try manifest.write(to: dir.appendingPathComponent("recording.json"))

        let events = EventRecorder.Events(
            version: 1, displayPixelSize: [screen.width, screen.height], backingScale: 1,
            duration: duration, cursor: [], clicks: clicks, apps: [])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(events).write(to: dir.appendingPathComponent("events.json"))

        var project = Project.makePhone(manifest: manifest, kind: kind)
        project.snippets = PhoneRecorder.snippets(from: take.marks, duration: duration)
        try project.write(to: dir)

        Log.line(String(format: "phone: %.1fs in %d file(s), %d taps, %d snippets",
                        duration, files.count, clicks.count, project.snippets.count))
        return dir
    }

    /// Marks come in pairs, start and end. An odd one out runs to the end.
    static func snippets(from marks: [Double], duration: Double) -> [Snippet] {
        stride(from: 0, to: marks.count, by: 2).compactMap { i in
            let start = marks[i]
            let end = i + 1 < marks.count ? marks[i + 1] : duration
            guard end - start > 0.3 else { return nil }
            return Snippet(name: "clip \(i / 2 + 1)", start: start, end: end)
        }
    }
}
