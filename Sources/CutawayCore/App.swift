import AppKit
import Foundation
import AVFoundation

private var base: String { Paths.recordingsRoot.path }
private let outputSize = CGSize(width: 1920, height: 1080)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var recordingDir = Paths.currentRecording.resolvingSymlinksInPath()
    private var preview: PreviewController?
    private let timelineView = TimelineView()
    private let sidebar = RecordingsSidebar()
    private let inspector = InspectorView()
    private let transcript = TranscriptPanel()
    private let timeLabel = NSTextField(labelWithString: "")
    private let statusLabel = Theme.label("", .meta, color: Theme.textTertiary)
    private let playButton = TransportButton(.play, prominent: true)
    private let undoButton = IconButton(.undo, transparent: true)
    private let redoButton = IconButton(.undo, transparent: true)
    private var watcher: FileWatcher?
    private var recorder: Recorder?
    private var tick: Timer?
    private var hotkey: Hotkey?
    private var countdown = Countdown()
    private let history = History()

    func applicationDidFinishLaunching(_ note: Notification) {
        Theme.apply()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 880),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Cutaway"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        window.minSize = NSSize(width: 1120, height: 720)

        if let engine = try? RenderEngine() {
            preview = PreviewController(engine: engine)
        } else {
            Log.line("no Metal device, preview disabled")
        }

        window.contentView = buildLayout()
        wireUp()

        Log.sink = { [weak self] s in
            DispatchQueue.main.async { self?.statusLabel.stringValue = s }
        }

        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Registered first so a take can start and stop without this window in shot.
        let hk = Hotkey()
        hk.register(.record) { [weak self] in self?.toggleRecord() }
        hk.register(.pause) { [weak self] in self?.togglePause() }
        hotkey = hk

        sidebar.reload(selected: recordingDir)
        reload()
        handleTriggers()
    }

    private func buildLayout() -> NSView {
        let root = Surface(Theme.canvas, radius: 0)
        let left = Surface(Theme.panel, radius: 0)
        let right = Surface(Theme.panel, radius: 0)
        let leftRule = Divider(), rightRule = Divider()

        let previewCard = Surface(Theme.inset, radius: Theme.radiusPanel)
        if let v = preview?.view {
            v.wantsLayer = true
            v.layer?.cornerRadius = 8
            v.layer?.masksToBounds = true
            v.translatesAutoresizingMaskIntoConstraints = false
            previewCard.addSubview(v)
            let fillWidth = v.widthAnchor.constraint(equalTo: previewCard.widthAnchor, constant: -24)
            fillWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: previewCard.centerXAnchor),
                v.centerYAnchor.constraint(equalTo: previewCard.centerYAnchor),
                v.widthAnchor.constraint(lessThanOrEqualTo: previewCard.widthAnchor, constant: -24),
                v.heightAnchor.constraint(lessThanOrEqualTo: previewCard.heightAnchor, constant: -24),
                v.heightAnchor.constraint(equalTo: v.widthAnchor, multiplier: 9.0 / 16.0),
                fillWidth,
            ])
        }

        let back = TransportButton(.back) { [weak self] in self?.skip(-5) }
        let forward = TransportButton(.forward) { [weak self] in self?.skip(5) }
        playButton.onClick = { [weak self] in self?.togglePlay() }
        undoButton.onClick = { [weak self] in self?.undo() }
        redoButton.onClick = { [weak self] in self?.redo() }
        redoButton.mirrored = true
        undoButton.isEnabled = false
        redoButton.isEnabled = false
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setTime(0, 0)

        let transport = NSStackView(views: [back, playButton, timeLabel, forward])
        transport.spacing = 10

        let timelineCard = Surface(Theme.inset, radius: Theme.radiusPanel)
        let timelineHeader = SectionHeader("Timeline", icon: .layers)
        let timelineHint = Theme.label("double-click a lane to add, drag to move",
                                       .meta, color: Theme.textTertiary)
        for v in [timelineHeader, timelineHint, timelineView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            timelineCard.addSubview(v)
        }

        let transcriptCard = Surface(Theme.inset, radius: Theme.radiusPanel)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcriptCard.addSubview(transcript)

        let views: [NSView] = [left, right, leftRule, rightRule, sidebar, inspector,
                               undoButton, redoButton, transport, statusLabel,
                               previewCard, timelineCard, transcriptCard]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        let center = NSLayoutGuide()
        root.addLayoutGuide(center)

        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.widthAnchor.constraint(equalToConstant: 240),
            leftRule.topAnchor.constraint(equalTo: root.topAnchor),
            leftRule.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            leftRule.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            leftRule.widthAnchor.constraint(equalToConstant: 1),

            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.widthAnchor.constraint(equalToConstant: 290),
            rightRule.topAnchor.constraint(equalTo: root.topAnchor),
            rightRule.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rightRule.trailingAnchor.constraint(equalTo: right.leadingAnchor),
            rightRule.widthAnchor.constraint(equalToConstant: 1),

            // traffic lights sit over the sidebar, so its content starts below them
            sidebar.topAnchor.constraint(equalTo: left.topAnchor, constant: 30),
            sidebar.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: left.bottomAnchor),

            inspector.topAnchor.constraint(equalTo: right.topAnchor),
            inspector.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            inspector.bottomAnchor.constraint(equalTo: right.bottomAnchor),

            center.leadingAnchor.constraint(equalTo: leftRule.trailingAnchor, constant: 16),
            center.trailingAnchor.constraint(equalTo: rightRule.leadingAnchor, constant: -16),
            center.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            center.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            undoButton.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            undoButton.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            undoButton.widthAnchor.constraint(equalToConstant: 28),
            undoButton.heightAnchor.constraint(equalToConstant: 28),
            redoButton.leadingAnchor.constraint(equalTo: undoButton.trailingAnchor, constant: 4),
            redoButton.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            redoButton.widthAnchor.constraint(equalToConstant: 28),
            redoButton.heightAnchor.constraint(equalToConstant: 28),

            transport.topAnchor.constraint(equalTo: center.topAnchor),
            transport.centerXAnchor.constraint(equalTo: center.centerXAnchor),
            transport.heightAnchor.constraint(equalToConstant: 32),

            statusLabel.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: transport.trailingAnchor,
                                                 constant: 24),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            previewCard.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 12),
            previewCard.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            previewCard.trailingAnchor.constraint(equalTo: center.trailingAnchor),

            timelineCard.topAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: 12),
            timelineCard.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            timelineCard.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            timelineHeader.topAnchor.constraint(equalTo: timelineCard.topAnchor, constant: 10),
            timelineHeader.leadingAnchor.constraint(equalTo: timelineCard.leadingAnchor, constant: 12),
            timelineHeader.widthAnchor.constraint(equalToConstant: 140),
            timelineHint.centerYAnchor.constraint(equalTo: timelineHeader.centerYAnchor),
            timelineHint.trailingAnchor.constraint(equalTo: timelineCard.trailingAnchor, constant: -12),
            timelineView.topAnchor.constraint(equalTo: timelineHeader.bottomAnchor, constant: 8),
            timelineView.leadingAnchor.constraint(equalTo: timelineCard.leadingAnchor, constant: 12),
            timelineView.trailingAnchor.constraint(equalTo: timelineCard.trailingAnchor, constant: -4),
            timelineView.heightAnchor.constraint(equalToConstant: TimelineView.preferredHeight),
            timelineView.bottomAnchor.constraint(equalTo: timelineCard.bottomAnchor, constant: -8),

            transcriptCard.topAnchor.constraint(equalTo: timelineCard.bottomAnchor, constant: 12),
            transcriptCard.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            transcriptCard.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            transcriptCard.bottomAnchor.constraint(equalTo: center.bottomAnchor),
            transcriptCard.heightAnchor.constraint(equalToConstant: 118),
            transcript.topAnchor.constraint(equalTo: transcriptCard.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: transcriptCard.bottomAnchor),
        ])
        return root
    }

    private func wireUp() {
        preview?.onTimeChange = { [weak self] t in
            guard let self, let p = self.preview else { return }
            let source = p.sourceTime
            self.timelineView.playhead = source
            self.transcript.update(time: source)
            self.inspector.update(time: source)
            self.setTime(t, p.duration)
            self.playButton.glyph = p.isPlaying ? .pause : .play
            self.sidebar.setPlaying(self.recordingDir, p.isPlaying)
        }

        timelineView.onSeek = { [weak self] sourceT in
            guard let self, let p = self.preview else { return }
            p.pause()
            p.seek(to: p.outputTime(forSource: sourceT))
        }

        timelineView.onNudgeZoomLevel = { [weak self] step in
            guard let self else { return }
            let t = self.preview?.sourceTime ?? 0
            self.editProject { p in
                guard let i = p.zooms.firstIndex(where: { t >= $0.start && t <= $0.end }) else { return }
                p.zooms[i].level = min(max(p.zooms[i].level + step, 1.1), 4.0)
            }
        }

        timelineView.onMoveZoom = { [weak self] index, edge, t in
            self?.editProject { p in
                guard index < p.zooms.count else { return }
                var z = p.zooms[index]
                let minLength = 0.4
                switch edge {
                case -1: z.start = min(max(0, t), z.end - minLength)
                case 1: z.end = max(t, z.start + minLength)
                default:
                    let length = z.end - z.start
                    z.start = max(0, t)
                    z.end = z.start + length
                }
                let half = (z.end - z.start) / 2
                z.inDuration = min(z.inDuration, half)
                z.outDuration = min(z.outDuration, half)
                p.zooms[index] = z
                p.zooms.sort { $0.start < $1.start }
            }
        }

        timelineView.onGestureBegan = { [weak self] in self?.history.beginGroup() }
        timelineView.onGestureEnded = { [weak self] in self?.history.endGroup() }

        timelineView.onAddZoom = { [weak self] t in
            guard let self else { return }
            let duration = self.timelineView.duration
            self.editProject { p in
                // kept inside the recording, or its end hides under the trim handle
                let end = min(t + 1.8, duration)
                var z = Zoom(start: max(0, min(t - 0.6, end - 0.6)), end: end, level: 2.0)
                z.anchor = [0.5, 0.5]
                p.zooms.append(z)
                p.zooms.sort { $0.start < $1.start }
            }
        }

        timelineView.onDeleteZoom = { [weak self] index in
            self?.editProject { p in
                guard index < p.zooms.count else { return }
                p.zooms.remove(at: index)
            }
        }

        timelineView.onTrim = { [weak self] isStart, t in
            guard let self else { return }
            let duration = self.timelineView.duration
            self.editProject { p in
                let end = p.trimEnd ?? duration
                if isStart { p.trimStart = min(max(0, t), end - 0.5) }
                else { p.trimEnd = max(t, p.trimStart + 0.5) }
            }
        }

        timelineView.onMoveScene = { [weak self] index, t in
            self?.editProject { p in
                var scenes = p.scenes.sorted { $0.at < $1.at }
                guard index > 0, index < scenes.count else { return }
                let lower = scenes[index - 1].at + 0.2
                let upper = index + 1 < scenes.count ? scenes[index + 1].at - 0.2 : .greatestFiniteMagnitude
                scenes[index].at = min(max(t, lower), upper)
                p.scenes = scenes
            }
        }

        timelineView.onAddScene = { [weak self] t in
            self?.editProject { p in
                var scenes = p.scenes.sorted { $0.at < $1.at }
                let previous = scenes.last(where: { $0.at <= t })?.layout ?? "screenOnly"
                scenes.append(Scene(at: t, layout: previous == "demo" ? "talkingHead" : "demo",
                                    transition: 0.6))
                p.scenes = scenes.sorted { $0.at < $1.at }
            }
        }

        sidebar.onSelect = { [weak self] url in self?.open(url) }
        sidebar.onPlay = { [weak self] url in
            guard let self else { return }
            if url.resolvingSymlinksInPath() != self.recordingDir { self.open(url) }
            self.togglePlay()
        }
        sidebar.onNewRecording = { [weak self] in self?.toggleRecord() }

        inspector.apply = { [weak self] change in self?.editProject(change) }
        inspector.onSeek = { [weak self] sourceT in
            guard let p = self?.preview else { return }
            p.pause()
            p.seek(to: p.outputTime(forSource: sourceT))
        }
        inspector.onExport = { [weak self] in self?.exportVideo() }
    }

    private func setTime(_ t: Double, _ total: Double) {
        func clock(_ v: Double) -> String {
            let s = Int(max(v, 0))
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                             : String(format: "%d:%02d", s / 60, s % 60)
        }
        let text = NSMutableAttributedString(string: clock(t), attributes: [
            .font: Theme.Text.time.font, .foregroundColor: Theme.textStrong])
        text.append(NSAttributedString(string: " / " + clock(total), attributes: [
            .font: Theme.Text.meta.font, .foregroundColor: Theme.textSecondary]))
        timeLabel.attributedStringValue = text
    }

    private func skip(_ seconds: Double) {
        guard let p = preview else { return }
        p.seek(to: min(max(p.currentTime + seconds, 0), p.duration))
    }

    /// Switches the editor to another take. Latest follows, so the CLI and the
    /// app always agree on which recording is current.
    private func open(_ url: URL) {
        preview?.pause()
        recordingDir = url.resolvingSymlinksInPath()
        Paths.linkLatest(to: recordingDir)
        watcher = nil
        history.clear()
        refreshHistoryButtons()
        sidebar.setSelected(recordingDir)
        reload()
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
        undoButton.isEnabled = history.canUndo
        redoButton.isEnabled = history.canRedo
    }

    // MARK: actions

    @objc private func togglePlay() {
        preview?.togglePlay()
        playButton.glyph = (preview?.isPlaying ?? false) ? .pause : .play
    }

    @objc private func reload() {
        guard FileManager.default.fileExists(
                atPath: recordingDir.appendingPathComponent("recording.json").path) else {
            Log.line("no recording yet, press New Recording or ⌘⇧8")
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
        timelineView.loadWaveform(from: recordingDir, manifest: m)
        timelineView.window?.invalidateCursorRects(for: timelineView)
        inspector.show(project, recording: recordingDir, duration: m.screen.duration)
        transcript.show(Transcript.load(from: recordingDir))
        preview?.load(recordingDir: recordingDir, outputSize: outputSize,
                      timeline: tl, screenSize: screenSize, webcamSize: webcamSize)
        Log.line(String(format: "%.0f×%.0f  60 fps", screenSize.width, screenSize.height))
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
        let target = Paths.newRecording()
        pendingTake = target
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
                try await r.start(to: target.appendingPathComponent("display.mov"))
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
                    if let take = self.pendingTake {
                        self.pendingTake = nil
                        self.sidebar.reload(selected: take)
                        self.open(take)
                    }
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

    private var pendingTake: URL?

    private func refreshRecordUI() {
        let r = recorder
        let live = r?.isRecording ?? false
        sidebar.newButton.title = live ? "Stop Recording" : "New Recording"
        if live, let r {
            statusLabel.stringValue = String(format: "%@ %.1fs", r.isPaused ? "paused" : "recording",
                                             r.elapsed)
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
                        try await Snapshot.captureWindow(
                            bundleID: Bundle.main.bundleIdentifier ?? "com.mintu.cutaway",
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
        else if consume("autointeract") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.interactionCheck() }
        }
        else if consume("autoexport") { exportVideo() }
        else if consume("autoplay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.preview?.seek(to: 2.4)
            }
        }
    }

    /// Fires real mouse events at the timeline and checks the edit landed on
    /// disk, since screenshots cannot tell you whether a drag did anything.
    private func interactionCheck() {
        let tl = timelineView
        func event(_ type: NSEvent.EventType, _ t: Double, _ lane: TimelineView.Lane,
                   clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let p = tl.convert(tl.point(at: t, lane: lane), to: nil)
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func click(_ t: Double, _ lane: TimelineView.Lane, clicks: Int = 1,
                   flags: NSEvent.ModifierFlags = []) {
            tl.mouseDown(with: event(.leftMouseDown, t, lane, clicks: clicks, flags: flags))
            tl.mouseUp(with: event(.leftMouseUp, t, lane, clicks: clicks, flags: flags))
        }
        func drag(_ from: Double, _ to: Double, _ lane: TimelineView.Lane) {
            tl.mouseDown(with: event(.leftMouseDown, from, lane))
            tl.mouseDragged(with: event(.leftMouseDragged, (from + to) / 2, lane))
            tl.mouseDragged(with: event(.leftMouseDragged, to, lane))
            tl.mouseUp(with: event(.leftMouseUp, to, lane))
        }
        func project() -> Project? { Project.load(from: recordingDir) }
        func report(_ name: String, _ ok: Bool, _ detail: String) {
            Log.line("interact: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        }

        // the check rewrites the edit, so put the real one back afterwards
        let original = project()
        defer {
            if let original { try? original.write(to: recordingDir) }
            history.clear()
            refreshHistoryButtons()
            reload()
        }

        editProject { p in
            p.zooms = [Zoom(start: 1.0, end: 2.5, level: 2.0)]
            p.trimStart = 0
            p.trimEnd = nil
        }

        click(4.0, .ruler)
        let seeked = preview?.sourceTime ?? -1
        report("seek", abs(seeked - 4.0) < 0.15, String(format: "playhead %.2f", seeked))

        drag(2.5, 3.5, .zoom)
        let end = project()?.zooms.first?.end ?? -1
        report("zoom edge drag", abs(end - 3.5) < 0.15, String(format: "end %.2f", end))

        drag(2.0, 2.6, .zoom)
        let moved = project()?.zooms.first
        report("zoom move", abs((moved?.start ?? -1) - 1.6) < 0.15,
               String(format: "start %.2f end %.2f", moved?.start ?? -1, moved?.end ?? -1))

        click(4.8, .zoom, clicks: 2)
        let added = project()?.zooms.count ?? -1
        report("double-click adds zoom", added == 2, "zooms \(added)")

        if let second = project()?.zooms.last {
            click((second.start + min(second.end, tl.duration)) / 2, .zoom, flags: .option)
        }
        let left = project()?.zooms.count ?? -1
        report("option-click deletes zoom", left == 1, "zooms \(left)")

        drag(0.0, 0.8, .wave)
        let trim = project()?.trimStart ?? -1
        report("trim start drag", abs(trim - 0.8) < 0.15, String(format: "trimStart %.2f", trim))

        undo()
        let undone = project()?.trimStart ?? -1
        report("undo reverts trim", undone < 0.05, String(format: "trimStart %.2f", undone))
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
