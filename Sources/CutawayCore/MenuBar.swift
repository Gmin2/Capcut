import AppKit

/// The menu bar item: the fastest way to start a capture or a take without
/// hunting for the window, and where the elapsed time shows while recording.
@MainActor
public final class MenuBarItem: NSObject {
    private let item: NSStatusItem
    private var recording = false

    public var onCaptureArea: (() -> Void)?
    public var onCaptureScreen: (() -> Void)?
    public var onCaptureScrolling: (() -> Void)?
    public var onNewRecording: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onHistory: (() -> Void)?
    public var onSettings: (() -> Void)?
    public var onOpenEditor: (() -> Void)?

    public override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = MenuBarItem.icon(recording: false)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Cutaway"
        rebuild()
    }

    /// While a take runs the item turns into a live timer, so it is obvious
    /// something is being recorded even with every window hidden.
    public func setRecording(_ live: Bool, elapsed: Double = 0, paused: Bool = false) {
        recording = live
        item.button?.image = MenuBarItem.icon(recording: live)
        item.button?.title = live
            ? String(format: " %@%d:%02d", paused ? "paused " : "", Int(elapsed) / 60, Int(elapsed) % 60)
            : ""
        rebuild()
    }

    private func rebuild() {
        let menu = NSMenu()
        if recording {
            add(menu, "Stop Recording", "⌘⇧8") { [weak self] in self?.onStop?() }
            add(menu, "Pause", "⌘⇧9") { [weak self] in self?.onPause?() }
        } else {
            add(menu, "Capture Area", "⌘⇧6") { [weak self] in self?.onCaptureArea?() }
            add(menu, "Capture Screen", "⌘⇧7") { [weak self] in self?.onCaptureScreen?() }
            add(menu, "Scrolling Capture", "⌘⇧5") { [weak self] in self?.onCaptureScrolling?() }
            menu.addItem(.separator())
            add(menu, "New Recording", "⌘⇧8") { [weak self] in self?.onNewRecording?() }
        }
        menu.addItem(.separator())
        add(menu, "Capture History", "⌘⇧H") { [weak self] in self?.onHistory?() }
        add(menu, "Open Cutaway", "") { [weak self] in self?.onOpenEditor?() }
        menu.addItem(.separator())
        add(menu, "Settings…", "⌘,") { [weak self] in self?.onSettings?() }
        let quit = NSMenuItem(title: "Quit Cutaway", action: #selector(NSApp.terminate(_:)),
                              keyEquivalent: "")
        menu.addItem(quit)
        item.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ keys: String, action: @escaping () -> Void) {
        let entry = ActionItem(title: title, keys: keys, action: action)
        menu.addItem(entry)
    }

    /// Drawn rather than an asset: a rounded frame with a dot, filled in while
    /// recording so the state reads at a glance.
    static func icon(recording: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let frame = NSRect(x: 1.5, y: 3.5, width: 15, height: 11)
            let path = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.6
            NSColor.black.setStroke()
            path.stroke()
            let dot = NSRect(x: rect.midX - 2.5, y: rect.midY - 2.5, width: 5, height: 5)
            NSColor.black.setFill()
            if recording {
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let ring = NSBezierPath(ovalIn: dot)
                ring.lineWidth = 1.4
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A menu item that runs a closure, so the menu can be built in one place.
private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, keys: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if !keys.isEmpty {
            let shortcut = Theme.label(keys, .meta, color: Theme.textTertiary)
            shortcut.sizeToFit()
            // the shortcut is shown as a hint: the real one is the global hotkey
            attributedTitle = NSAttributedString(string: "\(title)   \(keys)")
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
