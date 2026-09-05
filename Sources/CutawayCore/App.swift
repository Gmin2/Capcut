import AppKit
import Foundation
import AVFoundation

private let base = NSString(string: "~/coding/tools/video-editor/tmp/claude")
    .expandingTildeInPath
private var recordingDir: URL { URL(fileURLWithPath: base + "/recordings") }
private let outputSize = CGSize(width: 1920, height: 1080)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private var preview: PreviewController?
    private var timelineView = TimelineView()
    private var timeLabel = NSTextField(labelWithString: "0.00 / 0.00")
    private var playButton: NSButton!
    private var watcher: FileWatcher?
    private var recorder: Recorder?
    private var recordButton: NSButton!
    private var pauseButton: NSButton!
    private var recordLabel = NSTextField(labelWithString: "")
    private var tick: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 840),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Cutaway"
        window.center()

        if let engine = try? RenderEngine() {
            preview = PreviewController(engine: engine)
        } else {
            Log.line("ERROR: no Metal device, preview disabled")
        }

        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = NSColor.black.cgColor
        if let v = preview?.view {
            v.translatesAutoresizingMaskIntoConstraints = false
            previewBox.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
                v.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
                v.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
                v.heightAnchor.constraint(equalTo: v.widthAnchor, multiplier: 9.0 / 16.0),
            ])
        }

        playButton = NSButton(title: "Play", target: self, action: #selector(togglePlay))
        playButton.bezelStyle = .push
        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        recordButton = button("Record", #selector(toggleRecord))
        pauseButton = button("Pause", #selector(togglePause))
        pauseButton.isEnabled = false
        recordLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        recordLabel.textColor = .systemRed

        let transport = NSStackView(views: [
            playButton, timeLabel, NSView(),
            recordButton, pauseButton, recordLabel,
            button("Reload", #selector(reload)),
            button("Export", #selector(exportVideo)),
        ])
        transport.orientation = .horizontal
        transport.spacing = 8
        transport.distribution = .fill

        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.onSeek = { [weak self] t in
            self?.preview?.pause()
            self?.preview?.seek(to: t)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        textView = NSTextView()
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        scroll.documentView = textView

        let stack = NSStackView(views: [previewBox, transport, timelineView, scroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack

        NSLayoutConstraint.activate([
            previewBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            previewBox.heightAnchor.constraint(equalTo: previewBox.widthAnchor,
                                               multiplier: 9.0 / 16.0),
            timelineView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            timelineView.heightAnchor.constraint(equalToConstant: 70),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])

        preview?.onTimeChange = { [weak self] t in
            guard let self else { return }
            self.timelineView.playhead = t
            self.timeLabel.stringValue = String(format: "%.2f / %.2f",
                                                t, self.preview?.duration ?? 0)
            self.playButton.title = (self.preview?.isPlaying ?? false) ? "Pause" : "Play"
        }

        Log.sink = { [weak self] s in
            DispatchQueue.main.async { self?.append(s) }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let voices = VoiceoverRenderer.availableVoices()
        let premium = voices.filter { $0.quality != "default" }
        Log.line("voices: \(voices.count) english, \(premium.count) enhanced/premium")
        for v in premium.prefix(6) { Log.line("  \(v.name) [\(v.quality)]  \(v.identifier)") }

        reload()
        handleTriggers()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .push
        return b
    }

    private func append(_ s: String) {
        textView.textStorage?.append(NSAttributedString(
            string: s + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
        textView.scrollToEndOfDocument(nil)
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
                                  sourceDuration: m.screen.duration)

        // Live-reload the edit when project.json changes on disk, so an
        // external editor (or Claude) rewriting it updates the preview.
        if watcher == nil {
            let p = recordingDir.appendingPathComponent(Project.filename)
            watcher = FileWatcher(url: p) { [weak self] in
                Log.line("project.json changed, reloading")
                self?.reload()
            }
        }
        timelineView.duration = m.screen.duration
        timelineView.timeline = tl
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

        let r = Recorder()
        let sup = NSString(string: "~/Library/Application Support/Cutaway")
            .expandingTildeInPath
        func off(_ n: String) -> Bool {
            FileManager.default.fileExists(atPath: sup + "/" + n)
        }
        r.captureWebcam = !off("noWebcam")
        r.captureMicrophone = !off("noMic")
        r.captureSystemAudio = !off("noSystemAudio")
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
                    self.preview?.seek(to: 3.0)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    try? await Snapshot.captureDisplay(
                        to: URL(fileURLWithPath: base + "/editor.png"))
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
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    appDelegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

private nonisolated(unsafe) var appDelegate: AppDelegate?
