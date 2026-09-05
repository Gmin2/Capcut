import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Cutaway"
        window.center()

        let probe = NSButton(title: "Probe capture sources", target: self,
                             action: #selector(runProbe))
        probe.bezelStyle = .push

        let rec = NSButton(title: "Record 5s", target: self, action: #selector(record))
        rec.bezelStyle = .push

        let still = NSButton(title: "Render still", target: self, action: #selector(renderStill))
        still.bezelStyle = .push

        let exp = NSButton(title: "Export", target: self, action: #selector(exportVideo))
        exp.bezelStyle = .push

        let buttons = NSStackView(views: [probe, rec, still, exp])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        textView = NSTextView()
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        let stack = NSStackView(views: [buttons, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])

        Log.sink = { [weak self] s in
            DispatchQueue.main.async { self?.append(s) }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // lets the dev loop drive a recording without a human clicking
        // `open --env` is unreliable, so the dev loop drops a trigger file
        // instead. Consumed on read so it only fires once.
        let trigger = NSString(string: "~/Library/Application Support/Cutaway/autorecord")
            .expandingTildeInPath
        let stillTrigger = NSString(string: "~/Library/Application Support/Cutaway/autostill")
            .expandingTildeInPath
        let exportTrigger = NSString(string: "~/Library/Application Support/Cutaway/autoexport")
            .expandingTildeInPath
        if FileManager.default.fileExists(atPath: exportTrigger) {
            try? FileManager.default.removeItem(atPath: exportTrigger)
            exportVideo()
        } else if FileManager.default.fileExists(atPath: stillTrigger) {
            try? FileManager.default.removeItem(atPath: stillTrigger)
            renderStill()
        } else if FileManager.default.fileExists(atPath: trigger) {
            try? FileManager.default.removeItem(atPath: trigger)
            record()
        } else {
            runProbe()
        }
    }

    private func append(_ s: String) {
        textView.textStorage?.append(NSAttributedString(
            string: s + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func exportVideo() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        let base = NSString(string: "~/coding/tools/video-editor/tmp/claude")
            .expandingTildeInPath
        Task {
            do {
                try await Export.run(
                    mov: URL(fileURLWithPath: base + "/recordings/display.mov"),
                    to: URL(fileURLWithPath: base + "/export.mp4"))
            } catch { Log.line("ERROR: \(error)") }
        }
    }

    @objc private func renderStill() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        let base = NSString(string: "~/coding/tools/video-editor/tmp/claude")
            .expandingTildeInPath
        Task {
            do {
                try await Still.render(
                    mov: URL(fileURLWithPath: base + "/recordings/display.mov"),
                    at: 2.5,
                    to: URL(fileURLWithPath: base + "/still.png"))
            } catch { Log.line("ERROR: \(error)") }
        }
    }

    @objc private func record() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        let url = URL(fileURLWithPath: NSString(string:
            "~/coding/tools/video-editor/tmp/claude/recordings/display.mov")
            .expandingTildeInPath)
        Task {
            let r = Recorder()
            r.showCursorForVerification =
                FileManager.default.fileExists(atPath: NSString(
                    string: "~/Library/Application Support/Cutaway/verify")
                    .expandingTildeInPath)
            do { try await r.record(seconds: 5, to: url) }
            catch { Log.line("ERROR: \(error)") }
        }
    }

    @objc private func runProbe() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        Task { await Probe.listContent() }
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
    _ = delegate  // keep alive; NSApplication holds only a weak delegate
    appDelegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

private nonisolated(unsafe) var appDelegate: AppDelegate?
