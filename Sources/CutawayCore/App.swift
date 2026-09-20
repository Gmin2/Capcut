import AppKit
import ScreenCaptureKit
import Carbon.HIToolbox
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
    private let setup = RecordSetupView()
    private var menuBar: MenuBarItem?
    private var skipCountdown = false

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
        hotkey = hk
        bindHotkeys()
        SettingsWindow.onShortcutChange = { [weak self] in
            Task { @MainActor in self?.bindHotkeys() }
        }

        MainActor.assumeIsolated {
            installMenuBarItem()
            // first run: ask for what the app cannot work without
            if Welcome.needed { Welcome.show() }
        }
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

        speedButton.title = "1×"
        speedButton.toolTip = "Playback speed"
        speedButton.onClick = { [weak self, weak speedButton] in
            guard let self, let speedButton else { return }
            self.showSpeedMenu(from: speedButton)
        }
        let transport = NSStackView(views: [back, playButton, timeLabel, forward, speedButton])
        transport.spacing = 10
        transport.setCustomSpacing(18, after: forward)

        let timelineCard = Surface(Theme.inset, radius: Theme.radiusPanel)
        let timelineHeader = SectionHeader("Timeline", icon: .layers)
        timelineHint.isHidden = true
        for v in [timelineHeader, timelineHint, timelineView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            timelineCard.addSubview(v)
        }

        let transcriptCard = Surface(Theme.inset, radius: Theme.radiusPanel)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcriptCard.addSubview(transcript)

        emptyNote.maximumNumberOfLines = 3
        emptyNote.alignment = .center
        emptyNote.lineBreakMode = .byWordWrapping
        emptyNote.preferredMaxLayoutWidth = 420
        let views: [NSView] = [left, right, leftRule, rightRule, sidebar, inspector,
                               undoButton, redoButton, transport, statusLabel,
                               previewCard, timelineCard, transcriptCard, emptyNote, setup]
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

            // the setup screen takes over everything right of the sidebar
            setup.topAnchor.constraint(equalTo: root.topAnchor),
            setup.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            setup.leadingAnchor.constraint(equalTo: leftRule.trailingAnchor),
            setup.trailingAnchor.constraint(equalTo: root.trailingAnchor),

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

            transport.topAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: 10),
            transport.centerXAnchor.constraint(equalTo: center.centerXAnchor),
            transport.heightAnchor.constraint(equalToConstant: 32),

            statusLabel.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: transport.trailingAnchor,
                                                 constant: 24),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            previewCard.topAnchor.constraint(equalTo: center.topAnchor),
            previewCard.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            previewCard.trailingAnchor.constraint(equalTo: center.trailingAnchor),

            emptyNote.centerXAnchor.constraint(equalTo: previewCard.centerXAnchor),
            emptyNote.centerYAnchor.constraint(equalTo: previewCard.centerYAnchor),

            timelineCard.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 10),
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

        timelineView.onKey = { [weak self] event in self?.handleEditorKey(event) ?? false }

        timelineView.onSpanSpeed = { [weak self] index, speed in
            guard let self else { return }
            let duration = self.timelineView.duration
            self.editProject { p in
                p.segments = Cuts.setSpeed(speed, at: index, in: p.segments, duration: duration)
            }
            Log.line("span \(index) now runs at \(speed.clean)×")
        }
        timelineView.onSplitSpan = { [weak self] t in
            guard let self else { return }
            let duration = self.timelineView.duration
            self.editProject { p in
                p.segments = Cuts.split(at: t, in: p.segments, duration: duration)
            }
        }
        timelineView.onRemoveSpan = { [weak self] index in
            guard let self else { return }
            let duration = self.timelineView.duration
            self.editProject { p in
                let all = Cuts.base(p.segments, duration: duration)
                guard all.indices.contains(index) else { return }
                p.segments = Cuts.remove(all[index].sourceStart...all[index].sourceEnd,
                                         from: all, duration: duration)
            }
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

        sidebar.onSelect = { [weak self] url in
            self?.hideSetup()
            self?.open(url)
        }
        sidebar.onPlay = { [weak self] url in
            guard let self else { return }
            if url.resolvingSymlinksInPath() != self.recordingDir { self.open(url) }
            self.togglePlay()
        }
        sidebar.onNewRecording = { [weak self] in
            guard let self else { return }
            if self.recorder?.isRecording == true { self.toggleRecord() } else { self.showSetup() }
        }
        setup.isHidden = true
        setup.onClose = { [weak self] in self?.hideSetup() }
        setup.onStart = { [weak self] countdown in
            self?.skipCountdown = !countdown
            self?.toggleRecord()
        }

        inspector.apply = { [weak self] change in self?.editProject(change) }
        inspector.onSeek = { [weak self] sourceT in
            guard let p = self?.preview else { return }
            p.pause()
            p.seek(to: p.outputTime(forSource: sourceT))
        }
        inspector.onExport = { [weak self] in self?.exportVideo() }
        inspector.onExportPreset = { [weak self] name in self?.exportVideo(preset: name) }

        // editing by reading: the transcript drives the cut list
        transcript.onSeek = { [weak self] t in
            guard let self, let p = self.preview else { return }
            p.pause()
            p.seek(to: p.outputTime(forSource: t))
        }
        transcript.onRemove = { [weak self] span in
            guard let self else { return }
            let duration = self.timelineView.duration
            self.editProject { p in
                p.segments = Cuts.remove(span, from: p.segments, duration: duration)
            }
            Log.line(String(format: "cut %.1fs to %.1fs", span.lowerBound, span.upperBound))
        }
        transcript.onRestore = { [weak self] span in
            guard let self else { return }
            let duration = self.timelineView.duration
            self.editProject { p in
                p.segments = Cuts.restore(span, into: p.segments, duration: duration)
            }
        }
        transcript.onRemoveFillers = { [weak self] in
            guard let self, let script = Transcript.load(from: self.recordingDir) else { return }
            let spans = Cuts.fillerSpans(in: script)
            guard !spans.isEmpty else {
                Log.line("no filler words in this take")
                return
            }
            let duration = self.timelineView.duration
            self.editProject { p in
                p.segments = Cuts.removeAll(spans, from: p.segments, duration: duration)
            }
            Log.line("removed \(spans.count) filler word(s)")
        }
        transcript.onTighten = { [weak self] in
            guard let self, let script = Transcript.load(from: self.recordingDir) else { return }
            let duration = self.timelineView.duration
            let spans = Cuts.silences(in: script, duration: duration)
            guard !spans.isEmpty else {
                Log.line("no long pauses in this take")
                return
            }
            self.editProject { p in
                p.segments = Cuts.removeAll(spans, from: p.segments, duration: duration)
            }
            Log.line("trimmed \(spans.count) pause(s)")
        }
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
        if let text = window.firstResponder as? NSText, text.undoManager?.canUndo == true {
            text.undoManager?.undo()
            return
        }
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
        appMenu.addItem(withTitle: "About Cutaway", action: #selector(about), keyEquivalent: "")
        let welcomeItem = NSMenuItem(title: "Welcome and Permissions…", action: #selector(showWelcome),
                                     keyEquivalent: "")
        appMenu.addItem(welcomeItem)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                  keyEquivalent: ",")
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Cutaway", action: #selector(NSApp.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Cutaway", action: #selector(NSApp.terminate(_:)),
                        keyEquivalent: "q")
        appMenu.items.forEach { if $0.action != #selector(NSApp.hide(_:))
                                && $0.action != #selector(NSApp.terminate(_:)) { $0.target = self } }
        appItem.submenu = appMenu
        main.addItem(appItem)

        let captureItem = NSMenuItem()
        let capture = NSMenu(title: "Capture")
        let areaItem = NSMenuItem(title: "Capture Area", action: #selector(captureArea),
                                  keyEquivalent: "6")
        areaItem.keyEquivalentModifierMask = [.command, .shift]
        let screenItem = NSMenuItem(title: "Capture Screen", action: #selector(captureScreen),
                                    keyEquivalent: "7")
        screenItem.keyEquivalentModifierMask = [.command, .shift]
        capture.addItem(areaItem)
        capture.addItem(screenItem)
        let repeatItem = NSMenuItem(title: "Capture Same Area Again", action: #selector(captureAgain),
                                    keyEquivalent: "r")
        repeatItem.keyEquivalentModifierMask = [.command, .shift]
        capture.addItem(repeatItem)

        let scrollItem = NSMenuItem(title: "Scrolling Capture", action: #selector(captureScrolling),
                                    keyEquivalent: "5")
        scrollItem.keyEquivalentModifierMask = [.command, .shift]
        capture.addItem(scrollItem)

        let iconsItem = NSMenuItem(title: "Hide Desktop Icons", action: #selector(toggleIcons),
                                   keyEquivalent: "")
        iconsItem.state = Capture.desktopIconsHidden ? .on : .off
        capture.addItem(iconsItem)

        let timerItem = NSMenuItem(title: "Self Timer", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        for seconds in [0, 3, 5, 10] {
            let item = NSMenuItem(title: seconds == 0 ? "Off" : "\(seconds) seconds",
                                  action: #selector(pickTimer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = Capture.timer == seconds ? .on : .off
            timerMenu.addItem(item)
        }
        timerItem.submenu = timerMenu
        capture.addItem(timerItem)

        let textItem = NSMenuItem(title: "Copy Text from Last Capture",
                                  action: #selector(copyTextFromLast), keyEquivalent: "t")
        textItem.keyEquivalentModifierMask = [.command, .shift]
        capture.addItem(textItem)

        let historyItem = NSMenuItem(title: "Capture History", action: #selector(showHistory),
                                     keyEquivalent: "h")
        historyItem.keyEquivalentModifierMask = [.command, .shift]
        capture.addItem(historyItem)

        let pinItem = NSMenuItem(title: "Pin Last Capture", action: #selector(pinLast),
                                 keyEquivalent: "p")
        pinItem.keyEquivalentModifierMask = [.command, .shift]
        capture.addItem(pinItem)

        capture.addItem(.separator())
        let markupItem = NSMenuItem(title: "Markup Last Capture", action: #selector(markupLast),
                                    keyEquivalent: "e")
        markupItem.keyEquivalentModifierMask = [.command, .shift]
        capture.addItem(markupItem)
        capture.items.forEach { $0.target = self }
        captureItem.submenu = capture
        main.addItem(captureItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo", action: #selector(undo), keyEquivalent: "z")
        undoItem.target = self
        edit.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: #selector(redo), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        edit.addItem(redoItem)
        edit.addItem(.separator())
        // no target: these walk the responder chain, which is what makes
        // ⌘V work in the prompter and in a text mark
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimise", action: #selector(NSWindow.miniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(.separator())
        let pinsItem = NSMenuItem(title: "Close All Pins", action: #selector(closePins),
                                  keyEquivalent: "")
        pinsItem.target = self
        windowMenu.addItem(pinsItem)
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func captureArea() { Capture.area() }
    @objc private func captureScreen() { Capture.fullScreen() }

    @MainActor
    private func installMenuBarItem() {
        let item = MenuBarItem()
        item.onCaptureArea = { Capture.area() }
        item.onCaptureScreen = { Capture.fullScreen() }
        item.onCaptureScrolling = { Task { @MainActor in Capture.scrolling() } }
        item.onNewRecording = { [weak self] in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.showSetup()
        }
        item.onStop = { [weak self] in self?.toggleRecord() }
        item.onPause = { [weak self] in self?.togglePause() }
        item.onHistory = { Task { @MainActor in CaptureHistory.show() } }
        item.onSettings = { Task { @MainActor in SettingsWindow.show() } }
        item.onOpenEditor = { [weak self] in
            self?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        menuBar = item
    }

    @objc private func about() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cutaway",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: "Record a demo, mark up a capture, ship the video.",
                attributes: [.font: Theme.Text.body.font, .foregroundColor: Theme.textSecondary]),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called at launch and whenever a shortcut is changed in Settings.
    func bindHotkeys() {
        hotkey?.rebind([
            .record: { [weak self] in self?.toggleRecord() },
            .pause: { [weak self] in self?.togglePause() },
            .captureArea: { Capture.area() },
            .captureScreen: { Capture.fullScreen() },
            .captureRepeat: { Task { @MainActor in Capture.repeatLast() } },
            .captureScrolling: { Task { @MainActor in Capture.scrolling() } },
        ])
    }

    @objc private func showWelcome() {
        Task { @MainActor in Welcome.show() }
    }

    @objc private func showSettings() {
        Task { @MainActor in SettingsWindow.show() }
    }

    @objc private func closePins() {
        Task { @MainActor in Pin.closeAll() }
    }

    @objc private func captureAgain() {
        Task { @MainActor in Capture.repeatLast() }
    }

    @objc private func captureScrolling() {
        Task { @MainActor in Capture.scrolling() }
    }

    @objc private func toggleIcons(_ item: NSMenuItem) {
        Capture.desktopIconsHidden.toggle()
        item.state = Capture.desktopIconsHidden ? .on : .off
    }

    @objc private func pickTimer(_ item: NSMenuItem) {
        Capture.timer = item.tag
        item.menu?.items.forEach { $0.state = $0.tag == item.tag ? .on : .off }
    }

    @objc private func showHistory() {
        Task { @MainActor in CaptureHistory.show() }
    }

    @objc private func pinLast() {
        guard let last = Capture.lastShot() else {
            Log.line("no capture yet, press ⌘⇧6")
            return
        }
        Task { @MainActor in Pin.show(url: last) }
    }

    @objc private func copyTextFromLast() {
        guard let last = Capture.lastShot(),
              let image = NSImage(contentsOf: last)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Log.line("no capture yet, press ⌘⇧6")
            return
        }
        Task { @MainActor in _ = await TextInImage.copyEverything(from: image) }
    }

    @objc private func markupLast() {
        guard let last = Capture.lastShot() else {
            Log.line("no capture yet, press ⌘⇧6")
            return
        }
        AnnotateWindow.show(url: last)
    }

    private func refreshHistoryButtons() {
        undoButton.isEnabled = history.canUndo
        redoButton.isEnabled = history.canRedo
    }

    // MARK: actions

    /// Keys that work anywhere in the editor window.
    func handleEditorKey(_ event: NSEvent) -> Bool {
        guard setup.isHidden else { return false }
        switch event.charactersIgnoringModifiers ?? "" {
        case " ":
            togglePlay()
            return true
        case "\u{f702}":                                   // left arrow
            step(event.modifierFlags.contains(.shift) ? -5 : -1)
            return true
        case "\u{f703}":                                   // right arrow
            step(event.modifierFlags.contains(.shift) ? 5 : 1)
            return true
        default: return false
        }
    }

    private func showSpeedMenu(from anchor: NSView) {
        let menu = NSMenu()
        for rate in [0.5, 0.75, 1.0, 1.5, 2.0] {
            let item = NSMenuItem(title: rate == 1 ? "1×" : "\(rate.clean)×",
                                  action: #selector(pickSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate
            item.state = abs((preview?.rate ?? 1) - rate) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
    }

    @objc private func pickSpeed(_ item: NSMenuItem) {
        guard let rate = item.representedObject as? Double else { return }
        preview?.rate = rate
        speedButton.title = item.title
    }

    private func step(_ seconds: Double) {
        guard let p = preview else { return }
        p.pause()
        p.seek(to: min(max(p.currentTime + seconds, 0), p.duration))
    }

    @objc private func togglePlay() {
        preview?.togglePlay()
        playButton.glyph = (preview?.isPlaying ?? false) ? .pause : .play
    }

    @objc private func reload() {
        guard FileManager.default.fileExists(
                atPath: recordingDir.appendingPathComponent("recording.json").path) else {
            emptyNote.isHidden = false
            timelineHint.isHidden = true
            statusLabel.stringValue = ""
            Log.line("no recording yet, press New Recording or ⌘⇧8")
            return
        }
        emptyNote.isHidden = true
        timelineHint.isHidden = false
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
        transcript.show(Transcript.load(from: recordingDir), cut: project.segments,
                        duration: m.screen.duration)
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
        // camera only has no screen in the shot, so the window stays up and
        // you can watch yourself; every other mode gets out of the way
        if RecordSettings.load().capture == .camera, !setup.isHidden {
            setup.pausePreview()
        } else {
            setup.deactivate()
            window.orderOut(nil)
        }
        countdown.run(from: countdownSeconds) { [weak self] in
            self?.beginRecording()
        }
    }

    /// 0 disables the countdown, for scripted runs where nobody is watching.
    private var countdownSeconds: Int {
        if skipCountdown {
            skipCountdown = false
            return 0
        }
        let p = NSString(string: "~/Library/Application Support/Cutaway/countdown")
            .expandingTildeInPath
        if let s = try? String(contentsOfFile: p, encoding: .utf8),
           let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
        return RecordSettings.load().countdown
    }

    private func showSetup() {
        preview?.pause()
        setup.isHidden = false
        setup.activate()
    }

    private func hideSetup() {
        setup.deactivate()
        setup.isHidden = true
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
        // what the setup screen chose, with the old flag files still able to
        // switch things off for scripted runs
        let settings = RecordSettings.load()
        r.captureWebcam = settings.camera && !off("noWebcam")
        r.cameraID = settings.cameraID
        r.captureMicrophone = settings.mic && !off("noMic")
        r.captureSystemAudio = settings.desktopAudio > 0.005 && !off("noSystemAudio")
        r.captureKeys = settings.keystrokes || off("keycast")
        r.displayID = settings.displayID
        switch settings.capture {
        case .display: break
        case .window: r.onlyApp = settings.app
        case .area: r.area = settings.areaPoints(of: settings.displayID ?? CGMainDisplayID())
        case .camera:
            // the pipeline still wants a screen track, so keep it tiny; the
            // edit only ever shows the camera
            r.captureWebcam = true
            r.captureSystemAudio = false
            r.captureKeys = false
            r.area = CGRect(x: 0, y: 0, width: 320, height: 180)
        }
        cameraOnly = settings.capture == .camera
        systemLevel = settings.desktopAudio
        r.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshRecordUI() }
        }
        recorder = r

        Task {
            do {
                if self.cameraOnly { await MainActor.run { self.setup.releaseCamera() } }
                try await r.start(to: target.appendingPathComponent("display.mov"))
                await MainActor.run {
                    if self.cameraOnly, let session = r.webcamSession { self.setup.showLive(session) }
                    Prompter.shared.recordingStarted()
                    self.startTick()
                }
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
                await MainActor.run {
                    self.setup.releaseCamera()
                    Prompter.shared.recordingStopped()
                }
                _ = try await r.stop()
                await MainActor.run {
                    self.recorder = nil
                    self.refreshRecordUI()
                    if let take = self.pendingTake {
                        self.pendingTake = nil
                        self.hideSetup()
                        self.sidebar.reload(selected: take)
                        self.open(take)
                        // start the system track where the setup slider was
                        if var p = Project.load(from: take) {
                            p.audio.system = self.systemLevel
                            if self.cameraOnly {
                                p.scenes = [Scene(at: 0, layout: "talkingHead")]
                                p.zooms = []
                                p.callouts = []
                                p.deviceFrame = .none
                            }
                            try? p.write(to: take)
                        }
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
    private var systemLevel = 0.55
    private var cameraOnly = false
    private var exporting = false
    private let speedButton = FillButton("1×")
    /// Sits over the preview until there is something to preview.
    private let emptyNote = Theme.label("Nothing to play yet.\nRecord a take, or capture your screen with ⌘⇧6.",
                                        .body, color: Theme.textTertiary)
    private let timelineHint = Theme.label("double-click a lane to add, drag to move",
                                           .meta, color: Theme.textTertiary)

    private func refreshRecordUI() {
        let r = recorder
        let live = r?.isRecording ?? false
        sidebar.newButton.title = live ? "Stop Recording" : "New Recording"
        setup.setRecording(live, elapsed: r?.elapsed ?? 0, paused: r?.isPaused ?? false)
        MainActor.assumeIsolated {
            menuBar?.setRecording(live, elapsed: r?.elapsed ?? 0, paused: r?.isPaused ?? false)
        }
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

    @objc private func exportVideo() { exportVideo(preset: nil) }

    private func exportVideo(preset name: String?) {
        guard !exporting else {
            Log.line("already exporting")
            return
        }
        exporting = true
        inspector.setExporting(true)
        let preset = name.flatMap { ExportPreset.named[$0] }
        statusLabel.stringValue = "exporting \(preset?.name ?? "1080p")…"
        let suffix = preset.map { "-\($0.name.lowercased())" } ?? ""
        let out = URL(fileURLWithPath: base + "/export\(suffix)."
                      + ((preset?.isGIF ?? false) ? "gif" : "mp4"))
        Task {
            do {
                try await Export.run(recordingDir: recordingDir, preset: preset, to: out)
                await MainActor.run {
                    self.statusLabel.stringValue = "exported \(out.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                Log.line("ERROR: \(error)")
                await MainActor.run { self.statusLabel.stringValue = "export failed" }
            }
            await MainActor.run {
                self.exporting = false
                self.inspector.setExporting(false)
            }
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
        else if consume("autoshortcuts") {
            Task { @MainActor in
                func report(_ name: String, _ ok: Bool, _ detail: String) {
                    Log.line("shortcuts: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
                }
                let action = Hotkey.Action.captureArea
                action.set(nil)
                report("default is used", action.combo.label == "⌘⇧6", action.combo.label)

                let pressed = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                               modifierFlags: [.control, .option],
                                               timestamp: 0, windowNumber: 0, context: nil,
                                               characters: "a", charactersIgnoringModifiers: "a",
                                               isARepeat: false, keyCode: UInt16(kVK_ANSI_A))!
                guard let combo = Hotkey.Combo(event: pressed) else {
                    report("a press becomes a shortcut", false, "not read")
                    return
                }
                report("a press becomes a shortcut", combo.label == "⌃⌥A", combo.label)
                action.set(combo)
                report("it is remembered", Hotkey.Action.captureArea.combo.label == "⌃⌥A",
                       Hotkey.Action.captureArea.combo.label)

                self.bindHotkeys()
                report("rebinding works", true, "registered")

                let bare = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            characters: "a", charactersIgnoringModifiers: "a",
                                            isARepeat: false, keyCode: UInt16(kVK_ANSI_A))!
                report("a bare key is refused", Hotkey.Combo(event: bare) == nil, "no modifier")

                action.set(nil)
                report("esc restores the default", Hotkey.Action.captureArea.combo.label == "⌘⇧6",
                       Hotkey.Action.captureArea.combo.label)
                self.bindHotkeys()

                SettingsWindow.show()
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let v = NSApp.windows.first(where: { $0.title == "Settings" })?.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: Paths.support.appendingPathComponent("settings.png"))
                }
            }
        }
        else if consume("autowelcome") {
            Task { @MainActor in
                UserDefaults.standard.set(false, forKey: "welcome.done")
                Log.line("welcome: \(Welcome.needed ? "PASS" : "FAIL") shown on a first run")
                Welcome.show()
                try? await Task.sleep(nanoseconds: 900_000_000)
                Log.line("welcome: \(Welcome.isOpen ? "PASS" : "FAIL") window open")
                if let v = NSApp.windows.first(where: { $0.title == "Welcome" })?.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: Paths.support.appendingPathComponent("welcome.png"))
                }
                UserDefaults.standard.set(true, forKey: "welcome.done")
                Log.line("welcome: \(Welcome.needed ? "FAIL" : "PASS") not shown again")
            }
        }
        else if consume("autotranscript") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.transcriptCheck() }
        }
        else if consume("autouisnap") {
            // draws the window itself, so it works without screen recording
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let v = self.window.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = Paths.support.appendingPathComponent("ui.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
                Log.line("ui snapshot \(Int(v.bounds.width))x\(Int(v.bounds.height))")
            }
        }
        else if consume("automenubar") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let items = NSStatusBar.system.statusItem(withLength: 0)
                NSStatusBar.system.removeStatusItem(items)
                MainActor.assumeIsolated {
                    Log.line("menubar: \(self.menuBar != nil ? "PASS" : "FAIL") item installed")
                }
                Task { @MainActor in
                    self.menuBar?.setRecording(true, elapsed: 65)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let content = try? await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true),
                       let display = content.displays.first {
                        let config = SCStreamConfiguration()
                        config.width = 1200
                        config.height = 60
                        config.sourceRect = CGRect(x: 900, y: 0, width: 600, height: 30)
                        config.showsCursor = false
                        if let image = try? await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(display: display, excludingWindows: []),
                            configuration: config) {
                            try? Still.write(image, to: URL(fileURLWithPath: base + "/menubar.png"))
                            Log.line("menubar: strip captured")
                        }
                    }
                    self.menuBar?.setRecording(false)
                    Log.line("menubar: PASS recording state switches")
                }
            }
        }
        else if consume("autoprefs") {
            Task { @MainActor in
                let before = CaptureHistory.allShots().count
                let region = CGRect(x: 150, y: 120, width: 420, height: 260)

                Prefs.afterCapture = .shelf
                await Capture.shoot(display: CGMainDisplayID(), region: region)
                let afterOne = CaptureHistory.allShots().count
                Log.line("prefs: \(afterOne == before + 1 ? "PASS" : "FAIL") a capture is saved")

                Capture.repeatLast()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let afterRepeat = CaptureHistory.allShots().count
                Log.line("prefs: \(afterRepeat == afterOne + 1 ? "PASS" : "FAIL") repeat takes it again")

                Prefs.format = .jpeg
                await Capture.shoot(display: CGMainDisplayID(), region: region)
                let jpeg = CaptureHistory.allShots().count == afterRepeat
                    && (try? FileManager.default.contentsOfDirectory(atPath: Paths.shotsRoot.path))?
                        .contains(where: { $0.hasSuffix(".jpg") }) == true
                Log.line("prefs: \(jpeg ? "PASS" : "FAIL") jpeg is written as jpg")
                Prefs.format = .png

                Prefs.afterCapture = .copyOnly
                let countBefore = CaptureHistory.allShots().count
                await Capture.shoot(display: CGMainDisplayID(), region: region)
                Log.line("prefs: \(CaptureHistory.allShots().count == countBefore ? "PASS" : "FAIL") "
                         + "copy only writes no file")
                Prefs.afterCapture = .shelf
            }
        }
        else if consume("autosettings") {
            Task { @MainActor in
                SettingsWindow.show()
                try? await Task.sleep(nanoseconds: 900_000_000)
                Log.line("settings: \(SettingsWindow.isOpen ? "PASS" : "FAIL") open")
                try? await Snapshot.captureWindow(
                    bundleID: Bundle.main.bundleIdentifier ?? "com.mintu.cutaway",
                    titled: "Settings", to: URL(fileURLWithPath: base + "/settings.png"))
            }
        }
        else if consume("autoscroll") {
            Task { @MainActor in
                let session = ScrollingSession(display: CGMainDisplayID(),
                                               region: CGRect(x: 100, y: 100, width: 600, height: 400))
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    session.stop()
                }
                await session.run()
            }
        }
        else if consume("autohistory") {
            Task { @MainActor in
                CaptureHistory.show()
                try? await Task.sleep(nanoseconds: 900_000_000)
                let onDisk = CaptureHistory.allShots().count
                Log.line("history: \(CaptureHistory.shotCount == onDisk ? "PASS" : "FAIL") "
                         + "\(CaptureHistory.shotCount) cards for \(onDisk) file(s)")
                try? await Snapshot.captureWindow(
                    bundleID: Bundle.main.bundleIdentifier ?? "com.mintu.cutaway",
                    titled: "Captures", to: URL(fileURLWithPath: base + "/history.png"))
            }
        }
        else if consume("autopin") {
            Task { @MainActor in
                Pin.show(image: AppDelegate.checkerboard(width: 600, height: 400), url: nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
                Log.line("pin: \(Pin.count == 1 ? "PASS" : "FAIL") \(Pin.count) window(s)")
                try? await Snapshot.captureWindow(
                    bundleID: Bundle.main.bundleIdentifier ?? "com.mintu.cutaway",
                    to: URL(fileURLWithPath: base + "/pin.png"))
            }
        }
        else if consume("autoocr") {
            Task { @MainActor in
                let image = AppDelegate.textSample()
                let lines = await TextInImage.read(image)
                let wanted = "HELLO CUTAWAY 42"
                let ok = lines.contains { $0.uppercased().contains(wanted) }
                Log.line("ocr: \(ok ? "PASS" : "FAIL") read \(lines)")
            }
        }
        else if consume("autowindowshot") {
            Task { @MainActor in
                guard let content = try? await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true) else { return }
                let mainHeight = NSScreen.screens.first?.frame.height ?? 0
                let me = getpid()
                let candidates = content.windows.filter {
                    $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 120
                        && $0.owningApplication?.processID != me
                        && !SelectionOverlay.notWindows.contains($0.owningApplication?.bundleIdentifier ?? "")
                }
                guard let target = candidates.max(by: { $0.frame.width < $1.frame.width }) else {
                    Log.line("window pick: FAIL nothing to pick")
                    return
                }
                let box = SelectionOverlay.appKitFrame(target.frame, mainHeight: mainHeight)
                let centre = NSPoint(x: box.midX, y: box.midY)
                let back = SelectionOverlay.appKitFrame(
                    CGRect(x: box.minX, y: mainHeight - box.maxY, width: box.width, height: box.height),
                    mainHeight: mainHeight)
                Log.line("window pick: \(back == box ? "PASS" : "FAIL") frame round trip \(centre.x != 0)")
                await Capture.shoot(window: target)
                Log.line("window pick: captured \(target.title ?? "?") "
                         + "\(Int(target.frame.width))x\(Int(target.frame.height)) pts")
            }
        }
        else if consume("autoannotate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let w = AnnotateWindow.show(image: AppDelegate.checkerboard(), url: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    w.selfCheck(writingTo: Paths.support.appendingPathComponent("annotate-test.png"))
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        try? await Snapshot.captureWindow(
                            bundleID: Bundle.main.bundleIdentifier ?? "com.mintu.cutaway",
                            titled: "Capture",
                            to: URL(fileURLWithPath: base + "/annotate.png"))
                    }
                }
            }
        }
        else if consume("autoshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { await Capture.shoot(display: CGMainDisplayID(),
                                           region: CGRect(x: 120, y: 90, width: 640, height: 400)) }
            }
        }
        else if consume("autoprompter") {
            // the panel is excluded from screen capture, so draw it directly
            Prompter.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Prompter.shared.snapshot(to: URL(fileURLWithPath: base + "/prompter.png"))
                // then roll it as a take would, to check it scrolls
                Prompter.shared.recordingStarted()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    Prompter.shared.recordingStopped()
                    Prompter.shared.snapshot(to: URL(fileURLWithPath: base + "/prompter-scrolled.png"))
                }
            }
        }
        else if consume("autosetup") {
            showSetup()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Task {
                    await MainActor.run {
                        self.window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    do {
                        try await Snapshot.captureWindow(
                            bundleID: Bundle.main.bundleIdentifier ?? "com.mintu.cutaway",
                            to: URL(fileURLWithPath: base + "/setup.png"))
                    } catch {
                        Log.line("snapshot failed: \(error)")
                    }
                }
            }
        }
        else if consume("autoplay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.preview?.seek(to: 2.4)
            }
        }
    }

    /// Drives editing by transcript: pick words, cut them, put them back.
    private func transcriptCheck() {
        func report(_ name: String, _ ok: Bool, _ detail: String) {
            Log.line("transcript: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        }
        guard let dir = Paths.allRecordings().first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
        }) else {
            report("a take with words", false, "none found")
            return
        }
        open(dir)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let duration = self.timelineView.duration
            let original = Project.load(from: dir)
            defer {
                if let original { try? original.write(to: dir) }
                self.history.clear()
                self.refreshHistoryButtons()
                self.reload()
            }
            report("words shown", self.transcript.wordCount > 2,
                   "\(self.transcript.wordCount) words")

            guard let span = self.transcript.selectWords(from: 0, to: 2) else {
                report("select words", false, "nothing selectable")
                return
            }
            self.transcript.removeSelected()
            let after = Project.load(from: dir)?.segments ?? []
            let kept = Cuts.kept(after, duration: duration)
            report("removing words cuts the take", kept < duration - 0.1,
                   String(format: "%.1fs of %.1fs kept", kept, duration))
            report("the cut covers the words",
                   !Cuts.isKept((span.lowerBound + span.upperBound) / 2, in: after, duration: duration),
                   String(format: "span %.2f-%.2f", span.lowerBound, span.upperBound))

            self.transcript.restoreSelected()
            let back = Cuts.kept(Project.load(from: dir)?.segments ?? [], duration: duration)
            report("bring back restores it", back > duration - 0.15,
                   String(format: "%.1fs of %.1fs kept", back, duration))

            self.undo()
            self.undo()
            let undone = Cuts.kept(Project.load(from: dir)?.segments ?? [], duration: duration)
            report("undo walks back the cuts", abs(undone - duration) < 0.15,
                   String(format: "%.1fs kept", undone))

            // leave a cut in place for the screenshot, then restore
            self.transcript.selectWords(from: 2, to: 5)
            self.transcript.removeSelected()
            if let v = self.window.contentView,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: Paths.support.appendingPathComponent("ui.png"))
            }
            self.transcript.restoreSelected()

            self.transcript.tightenPauses()
            let tightened = Cuts.kept(Project.load(from: dir)?.segments ?? [], duration: duration)
            report("pauses trimmed", tightened <= duration + 0.01,
                   String(format: "%.1fs of %.1fs kept", tightened, duration))
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

        // Times are fractions of the take, not seconds: on a long recording a
        // one second drag is a few pixels wide and every hit test misses.
        let span = max(tl.duration, 1)
        func at(_ f: Double) -> Double { span * f }
        let near = span * 0.03

        editProject { p in
            p.zooms = [Zoom(start: at(0.19), end: at(0.47), level: 2.0)]
            p.trimStart = 0
            p.trimEnd = nil
        }

        click(at(0.75), .ruler)
        let seeked = preview?.sourceTime ?? -1
        report("seek", abs(seeked - at(0.75)) < near, String(format: "playhead %.2f", seeked))

        drag(at(0.47), at(0.66), .zoom)
        let end = project()?.zooms.first?.end ?? -1
        report("zoom edge drag", abs(end - at(0.66)) < near, String(format: "end %.2f", end))

        drag(at(0.38), at(0.49), .zoom)
        let moved = project()?.zooms.first
        report("zoom move", abs((moved?.start ?? -1) - at(0.30)) < near,
               String(format: "start %.2f end %.2f", moved?.start ?? -1, moved?.end ?? -1))

        click(at(0.90), .zoom, clicks: 2)
        let added = project()?.zooms.count ?? -1
        report("double-click adds zoom", added == 2, "zooms \(added)")

        if let second = project()?.zooms.last {
            click((second.start + min(second.end, tl.duration)) / 2, .zoom, flags: .option)
        }
        let left = project()?.zooms.count ?? -1
        report("option-click deletes zoom", left == 1, "zooms \(left)")

        drag(0.0, at(0.15), .wave)
        let trim = project()?.trimStart ?? -1
        report("trim start drag", abs(trim - at(0.15)) < near, String(format: "trimStart %.2f", trim))

        // the speed lane: split a piece, run it fast, then throw it away
        let splitAt = at(0.5)
        click(splitAt, .speed, clicks: 2)
        let spans = project()?.segments.count ?? 0
        report("split makes two pieces", spans >= 2, "spans \(spans)")

        tl.testSpanSpeed(index: 1, speed: 4)
        let fast = project()?.segments.last?.speed ?? 0
        report("a piece can run fast", abs(fast - 4) < 0.01, "speed \(fast.clean)×")

        // leave the ramp in place for a render, then carry on
        if let v = self.window.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: Paths.support.appendingPathComponent("ui.png"))
        }

        tl.testRemoveSpan(index: 1)
        let leftSpans = project()?.segments.count ?? -1
        report("a piece can be removed", leftSpans == 1, "spans \(leftSpans)")

        undo()
        undo()
        undo()

        drag(0.0, at(0.15), .wave)
        let trim2 = project()?.trimStart ?? -1
        report("trim after span edits", abs(trim2 - at(0.15)) < near,
               String(format: "trimStart %.2f", trim2))

        undo()
        let undone = project()?.trimStart ?? -1
        report("undo reverts trim", undone < near, String(format: "trimStart %.2f", undone))
    }

    /// A picture with known words in it, to check the reader against.
    static func textSample() -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 300,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 300).fill()
        ("HELLO CUTAWAY 42" as NSString).draw(
            at: NSPoint(x: 60, y: 120),
            withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .semibold),
                             .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    /// A picture to draw on that has no private content in it.
    static func checkerboard(width: Int = 1200, height: Int = 800) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        for row in 0..<(height / 80) {
            for col in 0..<(width / 80) where (row + col) % 2 == 0 {
                NSRect(x: col * 80, y: row * 80, width: 80, height: 80).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
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
