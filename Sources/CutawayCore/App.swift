import AppKit
import Foundation
import AVFoundation

private var base: String { Paths.recordingsRoot.path }
private var recordingDir: URL { Paths.currentRecording }
private let outputSize = CGSize(width: 1920, height: 1080)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var preview: PreviewController?
    private var timelineView = TimelineView()
    private var timeLabel = NSTextField(labelWithString: "0.00 / 0.00")
    private var playButton: FillButton!
    private var watcher: FileWatcher?
    private var recorder: Recorder?
    private var recordButton: FillButton!
    private var pauseButton: FillButton!
    private var recordLabel = NSTextField(labelWithString: "")
    private var tick: Timer?
    private var hotkey: Hotkey?
    private var countdown = Countdown()
    private let inspector = InspectorView()
    private var statusLabel = Theme.label("", .meta, color: Theme.textSecondary)
    private let history = History()
    private var undoButton: FillButton!
    private var redoButton: FillButton!

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 840),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Cutaway"
        window.center()
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.canvas
        window.minSize = NSSize(width: 980, height: 640)

        if let engine = try? RenderEngine() {
            preview = PreviewController(engine: engine)
        } else {
            Log.line("ERROR: no Metal device, preview disabled")
        }

        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = NSColor.black.cgColor
        previewBox.layer?.cornerRadius = Theme.radiusPanel
        previewBox.layer?.masksToBounds = true
        if let v = preview?.view {
            v.translatesAutoresizingMaskIntoConstraints = false
            previewBox.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
                v.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
                // Fits by whichever axis runs out first, so the frame is never
                // cropped and never stretched.
                v.widthAnchor.constraint(lessThanOrEqualTo: previewBox.widthAnchor),
                v.heightAnchor.constraint(lessThanOrEqualTo: previewBox.heightAnchor),
                v.heightAnchor.constraint(equalTo: v.widthAnchor, multiplier: 9.0 / 16.0),
                {
                    let w = v.widthAnchor.constraint(equalTo: previewBox.widthAnchor)
                    w.priority = .defaultHigh
                    return w
                }(),
            ])
        }

        playButton = FillButton("Play") { [weak self] in self?.togglePlay() }
        recordButton = FillButton("Record") { [weak self] in self?.toggleRecord() }
        recordButton.showsDot = true
        pauseButton = FillButton("Pause") { [weak self] in self?.togglePause() }
        pauseButton.isEnabled = false
        let exportButton = FillButton("Export", icon: .download) { [weak self] in self?.exportVideo() }

        timeLabel = Theme.label("0.00 / 0.00", .meta, color: Theme.textSecondary)
        recordLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        recordLabel.textColor = Theme.record

        undoButton = FillButton("Undo") { [weak self] in self?.undo() }
        redoButton = FillButton("Redo") { [weak self] in self?.redo() }
        undoButton.isEnabled = false
        redoButton.isEnabled = false

        let transport = NSStackView(views: [
            playButton, timeLabel, NSView(),
            undoButton, redoButton, NSView(),
            recordButton, pauseButton, recordLabel, NSView(),
            FillButton("Reload") { [weak self] in self?.reload() },
            exportButton,
        ])
        transport.orientation = .horizontal
        transport.spacing = 8

        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.wantsLayer = true
        timelineView.layer?.cornerRadius = Theme.radiusPanel
        timelineView.layer?.masksToBounds = true

        // The log used to take a quarter of the window. It is diagnostics, so
        // it belongs on one line where it can be read but not stared at.
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = Theme.textSecondary

        let left = NSStackView(views: [previewBox, transport, timelineView, statusLabel])
        left.orientation = .vertical
        left.spacing = Theme.gutter
        left.alignment = .leading
        // Only the preview stretches; the controls keep their natural height.
        left.setHuggingPriority(.defaultLow, for: .vertical)
        left.translatesAutoresizingMaskIntoConstraints = false

        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.apply = { [weak self] change in self?.editProject(change) }

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.canvas.cgColor
        root.addSubview(left)
        root.addSubview(inspector)
        window.contentView = root

        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor, constant: Theme.gutter),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.gutter),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.gutter),

            inspector.leadingAnchor.constraint(equalTo: left.trailingAnchor,
                                               constant: Theme.gutter),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: root.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 236),

            // The preview takes whatever space the fixed rows leave, so the
            // window never has dead area under the timeline.
            previewBox.widthAnchor.constraint(equalTo: left.widthAnchor),
            transport.widthAnchor.constraint(equalTo: left.widthAnchor),
            timelineView.widthAnchor.constraint(equalTo: left.widthAnchor),
            timelineView.heightAnchor.constraint(equalToConstant: 132),
            statusLabel.widthAnchor.constraint(equalTo: left.widthAnchor),
        ])

        preview?.onTimeChange = { [weak self] t in
            guard let self else { return }
            self.timelineView.playhead = self.preview?.sourceTime ?? t
            self.timeLabel.stringValue = String(format: "%.2f / %.2f",
                                                t, self.preview?.duration ?? 0)
            self.playButton.title = (self.preview?.isPlaying ?? false) ? "Pause" : "Play"
        }

        Log.sink = { [weak self] s in
            DispatchQueue.main.async { self?.statusLabel.stringValue = s }
        }

        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Registered before anything else so a take can be started and stopped
        // without ever touching this window, which would otherwise be in shot.
        let hk = Hotkey()
        let gotRecord = hk.register(.record) { [weak self] in self?.toggleRecord() }
        hk.register(.pause) { [weak self] in self?.togglePause() }
        hotkey = hk
        if gotRecord {
            Log.line("hotkeys: \(Hotkey.Combo.record.label) record/stop, "
                     + "\(Hotkey.Combo.pause.label) pause")
        }

        let voices = VoiceoverRenderer.availableVoices()
        let premium = voices.filter { $0.quality != "default" }
        Log.line("voices: \(voices.count) english, \(premium.count) enhanced/premium")
        for v in premium.prefix(6) { Log.line("  \(v.name) [\(v.quality)]  \(v.identifier)") }

        reload()
        handleTriggers()
    }

    /// Read, mutate, write. The file stays the single source of truth, so a UI
    /// edit and a scripted edit are the same operation.
    private func editProject(_ change: (inout Project) -> Void) {
        guard var p = Project.load(from: recordingDir) else { return }
        history.record(p)
        change(&p)
        do {
            try p.write(to: recordingDir)
        } catch {
            // Losing an edit silently is the worst failure here: the timeline
            // would snap back with no explanation.
            Log.line("could not save the edit: \(error.localizedDescription)")
            return
        }
        refreshHistoryButtons()
        reload()
    }

    @objc private func undo() {
        guard let current = Project.load(from: recordingDir),
              let previous = history.undo(current: current) else { return }
        history.replay { try? previous.write(to: recordingDir) }
        refreshHistoryButtons()
        reload()
        Log.line("undo")
    }

    @objc private func redo() {
        guard let current = Project.load(from: recordingDir),
              let next = history.redo(current: current) else { return }
        history.replay { try? next.write(to: recordingDir) }
        refreshHistoryButtons()
        reload()
        Log.line("redo")
    }

    /// A minimal menu, purely so the standard shortcuts work. Nobody reaches
    /// for an Undo button before they reach for command-Z.
    private func installMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Cutaway", action: #selector(NSApp.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(undo), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(redo),
                                  keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redoItem)
        edit.items.forEach { $0.target = self }
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func refreshHistoryButtons() {
        undoButton?.isEnabled = history.canUndo
        redoButton?.isEnabled = history.canRedo
    }

    // MARK: actions

    @objc private func togglePlay() {
        preview?.togglePlay()
        playButton.title = (preview?.isPlaying ?? false) ? "Pause" : "Play"
    }

    @objc private func reload() {
        guard FileManager.default.fileExists(
                atPath: recordingDir.appendingPathComponent("recording.json").path) else {
            Log.line("no recording yet - hit Record")
            return
        }
        guard let m = Manifest.load(from: recordingDir.appendingPathComponent("recording.json"))
        else { return }

        let screenSize = CGSize(width: m.screen.pixelSize[0], height: m.screen.pixelSize[1])
        let webcamSize = m.webcam.map { CGSize(width: $0.pixelSize[0], height: $0.pixelSize[1]) }
        let project = Export.loadOrCreateProject(recordingDir: recordingDir,
                                                 screenSize: screenSize,
                                                 duration: m.screen.duration,
                                                 hasWebcam: m.webcam != nil)
        let tl = project.timeline(sourceSize: screenSize,
                                  events: Events.load(from: recordingDir),
                                  sourceDuration: m.screen.duration,
                                  transcript: Transcript.load(from: recordingDir))

        // Live-reload the edit when project.json changes on disk, so an
        // external editor (or Claude) rewriting it updates the preview.
        if watcher == nil {
            let p = recordingDir.appendingPathComponent(Project.filename)
            watcher = FileWatcher(url: p) { [weak self] in
                Log.line("project.json changed, reloading")
                self?.reload()
            }
        }
        // The strip is drawn in source time so cut spans stay visible; the
        // playhead is mapped in from edited time.
        timelineView.duration = m.screen.duration
        timelineView.timeline = tl
        timelineView.loadThumbnails(
            from: recordingDir.appendingPathComponent(m.screen.file))
        timelineView.loadWaveform(from: recordingDir, manifest: m)
        timelineView.window?.invalidateCursorRects(for: timelineView)
        inspector.show(project)
        preview?.load(recordingDir: recordingDir, outputSize: outputSize,
                      timeline: tl, screenSize: screenSize, webcamSize: webcamSize)
        Log.line(String(format: "loaded %.2fs  screen %.0fx%.0f  webcam %@  %d scenes  %d zooms  %d vo lines",
                        m.screen.duration, screenSize.width, screenSize.height,
                        webcamSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none",
                        project.scenes.count, project.zooms.count,
                        project.voiceover?.lines.count ?? 0))
        if !tl.timeMap.isIdentity {
            Log.line(String(format: "  cuts: %d segments, %.2fs -> %.2fs",
                            tl.timeMap.segments.count, m.screen.duration,
                            tl.timeMap.outputDuration))
        }
    }

    @objc private func toggleRecord() {
        if let r = recorder, r.isRecording { stopRecording(r); return }
        preview?.pause()

        // Hide first, then count down, so the window is out of shot before the
        // first frame rather than being cut out afterwards.
        window.orderOut(nil)
        countdown.run(from: countdownSeconds) { [weak self] in
            self?.beginRecording()
        }
    }

    /// 0 disables the countdown, for scripted runs where nobody is watching.
    private var countdownSeconds: Int {
        let p = NSString(string: "~/Library/Application Support/Cutaway/countdown")
            .expandingTildeInPath
        if let s = try? String(contentsOfFile: p, encoding: .utf8),
           let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
        return 3
    }

    private func beginRecording() {
        let r = Recorder()
        let sup = NSString(string: "~/Library/Application Support/Cutaway")
            .expandingTildeInPath
        func off(_ n: String) -> Bool {
            FileManager.default.fileExists(atPath: sup + "/" + n)
        }
        r.captureWebcam = !off("noWebcam")
        r.captureMicrophone = !off("noMic")
        r.captureSystemAudio = !off("noSystemAudio")
        r.captureKeys = off("keycast")
        r.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshRecordUI() }
        }
        recorder = r

        Task {
            do {
                try await r.start(to: recordingDir.appendingPathComponent("display.mov"))
                await MainActor.run { self.startTick() }
            } catch {
                Log.line("ERROR: \(error)")
                await MainActor.run { self.recorder = nil; self.refreshRecordUI() }
            }
        }
    }

    private func stopRecording(_ r: Recorder) {
        stopTick()
        // Bring the editor back so the result is right there when it lands.
        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do {
                _ = try await r.stop()
                await MainActor.run {
                    self.recorder = nil
                    self.refreshRecordUI()
                    self.reload()
                }
            } catch { Log.line("ERROR: \(error)") }
        }
    }

    @objc private func togglePause() {
        guard let r = recorder, r.isRecording else { return }
        r.isPaused ? r.resume() : r.pause()
        refreshRecordUI()
    }

    private func startTick() {
        stopTick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshRecordUI()
        }
        refreshRecordUI()
    }

    private func stopTick() { tick?.invalidate(); tick = nil }

    private func refreshRecordUI() {
        let r = recorder
        let live = r?.isRecording ?? false
        recordButton.title = live ? "Stop" : "Record"
        pauseButton.isEnabled = live
        pauseButton.title = (r?.isPaused ?? false) ? "Resume" : "Pause"
        if live, let r {
            recordLabel.stringValue = String(format: "%@ %.1fs",
                                             r.isPaused ? "PAUSED" : "REC", r.elapsed)
            recordLabel.textColor = r.isPaused ? .systemOrange : .systemRed
        } else {
            recordLabel.stringValue = ""
        }
    }

    /// Renders a sweep of composited frames to PNG. Faster than a full export
    /// when judging a layout or the look of the cursor.
    /// Overridable from disk so a verification sweep can target any moments.
    private var stillTimes: [Double] {
        let p = NSString(string: "~/Library/Application Support/Cutaway/stilltimes")
            .expandingTildeInPath
        if let text = try? String(contentsOfFile: p, encoding: .utf8) {
            let v = text.split(whereSeparator: { ", \n".contains($0) })
                        .compactMap { Double($0) }
            if !v.isEmpty { return v }
        }
        return [1.25, 1.85, 2.30, 3.40]
    }

    @objc private func renderStill() {
        Log.line("renderStill: \(stillTimes)")
        Task {
            for (i, t) in stillTimes.enumerated() {
                do {
                    try await Still.render(recordingDir: recordingDir, at: t,
                                           to: URL(fileURLWithPath: base + "/still\(i + 1).png"))
                } catch { Log.line("ERROR: \(error)") }
            }
        }
    }

    @objc private func exportVideo() {
        Task {
            do {
                try await Export.run(recordingDir: recordingDir,
                                     to: URL(fileURLWithPath: base + "/export.mp4"))
            } catch { Log.line("ERROR: \(error)") }
        }
    }

    /// Lets the dev loop drive the app without a human clicking.
    private func handleTriggers() {
        let dir = NSString(string: "~/Library/Application Support/Cutaway")
            .expandingTildeInPath
        func consume(_ name: String) -> Bool {
            let p = dir + "/" + name
            guard FileManager.default.fileExists(atPath: p) else { return false }
            try? FileManager.default.removeItem(atPath: p)
            return true
        }
        if consume("autotranscribe") {
            Task {
                let audio = recordingDir.appendingPathComponent("voiceover.m4a")
                do {
                    let t = try await Transcriber.run(audio: audio, offset: 0)
                    try t.write(to: recordingDir)
                    for s in t.sentences() {
                        Log.line(String(format: "  [%.2f-%.2f] %@",
                                        s.t, s.t + s.duration, s.text))
                    }
                } catch { Log.line("ERROR: \(error.localizedDescription)") }
            }
        }
        else if consume("autostill") {
            renderStill()
        }
        else if consume("autosnap") {
            // Give the preview a moment to load and draw a real frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                Task {
                    // Bring the window forward first, or the snapshot is
                    // whatever happens to be in front of it.
                    await MainActor.run {
                        self.window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.preview?.seek(to: 3.0)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    do {
                        try await Snapshot.captureDisplay(
                            to: URL(fileURLWithPath: base + "/editor.png"))
                    } catch {
                        Log.line("snapshot failed: \(error)")
                    }
                }
            }
        }
        else if consume("autorecord") {
            // Records, pauses partway, resumes, then stops: exercises the whole
            // transport without a human clicking.
            toggleRecord()
            let script: [(Double, () -> Void)] = [
                (3.0, { [weak self] in self?.togglePause() }),
                (5.0, { [weak self] in self?.togglePause() }),
                (8.0, { [weak self] in
                    if let r = self?.recorder { self?.stopRecording(r) } }),
            ]
            for (delay, action) in script {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            }
        }
        else if consume("autoexport") { exportVideo() }
        else if consume("autoplay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.preview?.seek(to: 2.4)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

/// Entry point the host bundle dlopens. Everything above this line can be
/// rebuilt freely without touching the signed app.
@_cdecl("cutaway_main")
public func cutaway_main() {
    // Arguments mean headless. Same bundle either way, which matters because
    // the screen-recording grant is attached to this bundle's identity: a
    // separate CLI binary would need its own.
    // A request left by the CLI takes priority: this launch exists to serve it.
    if let pending = CLI.takePendingRequest() {
        Log.toStdout = true
        exit(runBlocking { await CLI.run(pending) })
    }

    let args = Array(CommandLine.arguments.dropFirst())
        .filter { !$0.hasPrefix("-psn") }
    if !args.isEmpty {
        Log.toStdout = true
        // Screen capture needs the app itself to be the responsible process.
        // Exec'ing the binary directly makes TCC attribute the request to the
        // parent shell instead, and it is denied. Relaunching through the
        // bundle with `open` fixes attribution; the child writes its result to
        // a pipe file so the CLI can still print it.
        // Capture needs the app itself to be the responsible process; a direct
        // exec makes TCC blame the parent shell.
        if CLI.needsAppLaunch(args) {
            // Recording runs for its full duration; everything else is quick.
            let budget: Double = args.first == "record"
                ? (args.firstIndex(of: "--seconds").flatMap { i in
                        i + 1 < args.count ? Double(args[i + 1]) : nil } ?? 10) + 60
                : 60
            exit(CLI.relaunchThroughBundle(args, timeout: budget))
        }
        let code = runBlocking { await CLI.run(args) }
        // exit rather than return: a capture session can leave a run loop
        // source alive, and a CLI that does not quit hangs its caller.
        exit(code)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    appDelegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

private nonisolated(unsafe) var appDelegate: AppDelegate?

/// Bridges the async CLI into a plain main(). A semaphore rather than a
/// RunLoop: several capture APIs post to the main queue, so the main thread has
/// to keep pumping while the work runs.
private func runBlocking(_ body: @escaping () async -> Int32) -> Int32 {
    var result: Int32 = 0
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        result = await body()
        done.signal()
    }
    while done.wait(timeout: .now() + 0.02) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return result
}
