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

        let transport = NSStackView(views: [
            playButton, timeLabel, NSView(),
            button("Record 8s", #selector(record)),
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
        let tl = Export.defaultTimeline(recordingDir: recordingDir,
                                        screenSize: screenSize,
                                        duration: m.screen.duration,
                                        hasWebcam: m.webcam != nil)
        timelineView.duration = m.screen.duration
        timelineView.timeline = tl
        preview?.load(recordingDir: recordingDir, outputSize: outputSize,
                      timeline: tl, screenSize: screenSize, webcamSize: webcamSize)
        Log.line(String(format: "loaded %.2fs, screen %.0fx%.0f, webcam %@",
                        m.screen.duration, screenSize.width, screenSize.height,
                        webcamSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"))
    }

    @objc private func record() {
        preview?.pause()
        Task {
            let r = Recorder()
            r.captureWebcam = !FileManager.default.fileExists(atPath: NSString(
                string: "~/Library/Application Support/Cutaway/noWebcam").expandingTildeInPath)
            do {
                try await r.record(seconds: 8,
                                   to: recordingDir.appendingPathComponent("display.mov"))
                await MainActor.run { self.reload() }
            } catch { Log.line("ERROR: \(error)") }
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
        if consume("autosnap") {
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
        else if consume("autorecord") { record() }
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
