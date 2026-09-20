import AppKit
import AVFoundation

/// What Cutaway does with a capture once it has one, and where it puts it.
public enum Prefs {

    public enum AfterCapture: String, CaseIterable {
        case shelf = "Show the shelf"
        case markup = "Open markup"
        case copyOnly = "Copy only"
    }

    public enum Format: String, CaseIterable {
        case png = "PNG"
        case jpeg = "JPEG"

        var ext: String { self == .png ? "png" : "jpg" }
    }

    public static var afterCapture: AfterCapture {
        get { AfterCapture(rawValue: UserDefaults.standard.string(forKey: "capture.after") ?? "") ?? .shelf }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "capture.after") }
    }

    public static var format: Format {
        get { Format(rawValue: UserDefaults.standard.string(forKey: "capture.format") ?? "") ?? .png }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "capture.format") }
    }

    /// Nil means the default, ~/Pictures/Cutaway.
    public static var saveFolder: URL? {
        get { UserDefaults.standard.string(forKey: "capture.folder").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "capture.folder") }
    }

    public static var playsSound: Bool {
        get { UserDefaults.standard.object(forKey: "capture.sound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "capture.sound") }
    }
}

/// One window for everything that is a choice rather than an action: where
/// captures go, what happens after one, and which permissions are still
/// missing, since nothing works without those.
@MainActor
public final class SettingsWindow: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private static var shared: SettingsWindow?

    private let window: NSWindow
    private let folderLabel = Theme.label("", .meta, color: Theme.textSecondary)
    private var permissionRows: [PermissionRow] = []

    /// Set by the app, so changing a shortcut re-registers it at once.
    nonisolated(unsafe) public static var onShortcutChange: (() -> Void)?

    public static func show() {
        if let shared {
            shared.refresh()
            shared.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        shared = SettingsWindow()
    }

    static var isOpen: Bool { shared != nil }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.center()
        window.contentView = buildLayout()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    private func buildLayout() -> NSView {
        let root = Surface(Theme.canvas, radius: 0)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(Theme.label("Settings", .title))

        stack.addArrangedSubview(SectionHeader("Captures", icon: .area))
        stack.addArrangedSubview(row("After a capture",
                                     Dropdown(Prefs.AfterCapture.allCases.map(\.rawValue),
                                              selected: Prefs.afterCapture.rawValue) { value in
            Prefs.afterCapture = Prefs.AfterCapture(rawValue: value) ?? .shelf
        }))
        stack.addArrangedSubview(row("Image format",
                                     Dropdown(Prefs.Format.allCases.map(\.rawValue),
                                              selected: Prefs.format.rawValue) { value in
            Prefs.format = Prefs.Format(rawValue: value) ?? .png
        }))
        stack.addArrangedSubview(row("Self timer",
                                     Dropdown(["Off", "3 seconds", "5 seconds", "10 seconds"],
                                              selected: Capture.timer == 0 ? "Off" : "\(Capture.timer) seconds") { value in
            Capture.timer = Int(value.prefix(2).trimmingCharacters(in: .whitespaces)) ?? 0
        }))

        let change = FillButton("Change", icon: .folder) { [weak self] in self?.pickFolder() }
        let folderRow = NSStackView(views: [Theme.label("Save to", .body), folderLabel, change])
        folderRow.spacing = 10
        stack.addArrangedSubview(folderRow)

        let sound = Switch(Prefs.playsSound)
        sound.onChange = { Prefs.playsSound = $0 }
        stack.addArrangedSubview(row("Shutter sound", sound))

        let icons = Switch(Capture.desktopIconsHidden)
        icons.onChange = { on in Capture.desktopIconsHidden = on }
        stack.addArrangedSubview(row("Hide desktop icons", icons))

        stack.addArrangedSubview(SectionHeader("Appearance", icon: .gear))
        stack.addArrangedSubview(row("Theme",
                                     Dropdown(["Light", "Dark", "Match system"],
                                              selected: Theme.mode == "dark" ? "Dark"
                                                : Theme.mode == "system" ? "Match system" : "Light") { value in
            Theme.mode = value == "Dark" ? "dark" : value == "Match system" ? "system" : "light"
        }))

        stack.addArrangedSubview(SectionHeader("Permissions", icon: .keyboard))
        for check in PermissionRow.Kind.allCases {
            let r = PermissionRow(kind: check)
            permissionRows.append(r)
            stack.addArrangedSubview(r)
        }

        stack.addArrangedSubview(SectionHeader("Shortcuts", icon: .keyboard))
        for action in Hotkey.Action.allCases {
            let label = Theme.label(action.title, .body)
            label.widthAnchor.constraint(equalToConstant: 230).isActive = true
            let field = ShortcutField(action: action) { SettingsWindow.onShortcutChange?() }
            let line = NSStackView(views: [label, field])
            line.spacing = 12
            line.alignment = .centerY
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            field.heightAnchor.constraint(equalToConstant: 28).isActive = true
            stack.addArrangedSubview(line)
        }
        stack.addArrangedSubview(Theme.label(
            "Click a shortcut, then press the keys you want. Esc puts the default back.",
            .meta, color: Theme.textTertiary))

        // the rest are menu items, which macOS owns
        for (keys, what) in [("⌘⇧H", "Capture history"),
                             ("⌘⇧E", "Mark up the last capture"),
                             ("⌘⇧T", "Copy the text in the last capture"),
                             ("⌘⇧P", "Pin the last capture")] {
            let keyLabel = Theme.label(keys, .bodyStrong)
            keyLabel.alignment = .right
            let line = NSStackView(views: [keyLabel, Theme.label(what, .body, color: Theme.textSecondary)])
            line.spacing = 12
            keyLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
            stack.addArrangedSubview(line)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let holder = FlippedStack()
        holder.orientation = .vertical
        holder.alignment = .leading
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addArrangedSubview(stack)
        scroll.documentView = holder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            holder.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return root
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = Theme.label(title, .body)
        label.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let line = NSStackView(views: [label, control])
        line.spacing = 12
        line.alignment = .centerY
        return line
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Paths.shotsRoot
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.saveFolder = url
        refresh()
    }

    func refresh() {
        folderLabel.stringValue = Paths.shotsRoot.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        permissionRows.forEach { $0.refresh() }
    }

    public func windowWillClose(_ notification: Notification) {
        SettingsWindow.shared = nil
    }
}

/// One permission, whether it is granted, and a way to go and fix it.
final class PermissionRow: ThemedView {
    enum Kind: CaseIterable {
        case screen, microphone, camera, inputMonitoring

        var title: String {
            switch self {
            case .screen: return "Screen recording"
            case .microphone: return "Microphone"
            case .camera: return "Camera"
            case .inputMonitoring: return "Input monitoring"
            }
        }

        var why: String {
            switch self {
            case .screen: return "captures and recordings"
            case .microphone: return "narration"
            case .camera: return "the facecam"
            case .inputMonitoring: return "the keystroke overlay"
            }
        }

        var settingsPane: String {
            switch self {
            case .screen: return "Privacy_ScreenCapture"
            case .microphone: return "Privacy_Microphone"
            case .camera: return "Privacy_Camera"
            case .inputMonitoring: return "Privacy_ListenEvent"
            }
        }

        var granted: Bool {
            switch self {
            case .screen: return CGPreflightScreenCaptureAccess()
            case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            case .inputMonitoring: return EventRecorder.canCaptureKeys
            }
        }
    }

    private let kind: Kind
    private let status = Theme.label("", .meta, color: Theme.textSecondary)

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        let title = Theme.label(kind.title, .body)
        title.widthAnchor.constraint(equalToConstant: 150).isActive = true
        // fixed, or a long "needed for" line pushes the button off the window
        status.widthAnchor.constraint(equalToConstant: 200).isActive = true
        status.lineBreakMode = .byTruncatingTail
        let open = FillButton("Open") { [weak self] in self?.openSettings() }
        let line = NSStackView(views: [title, status, open])
        line.spacing = 12
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            open.heightAnchor.constraint(equalToConstant: 26),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let ok = kind.granted
        status.stringValue = ok ? "granted" : "needed for \(kind.why)"
        status.textColor = ok ? Theme.textSecondary : Theme.record
    }

    private func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)")
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// Click it, press the keys, done. Esc puts the default back.
final class ShortcutField: Control {
    private let action: Hotkey.Action
    private let onChange: () -> Void
    private var listening = false { didSet { needsDisplay = true } }
    private var monitor: Any?

    init(action: Hotkey.Action, onChange: @escaping () -> Void) {
        self.action = action
        self.onChange = onChange
        super.init(frame: .zero)
        onClick = { [weak self] in self?.listen() }
        toolTip = "Click, then press the keys"
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusControl, yRadius: Theme.radiusControl)
        (listening ? Theme.canvas : fillColor).setFill()
        path.fill()
        if listening {
            path.lineWidth = Theme.borderSelected
            Theme.accentBorder.setStroke()
            path.stroke()
        }
        let text = (listening ? "press keys…" : action.combo.label) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Text.bodyStrong.font,
            .foregroundColor: listening ? Theme.textTertiary : Theme.textPrimary,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                  withAttributes: attrs)
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.stop()
            if event.keyCode == 53 {                       // esc: back to the default
                self.action.set(nil)
            } else if let combo = Hotkey.Combo(event: event) {
                self.action.set(combo)
            } else {
                Log.line("a shortcut needs a modifier, or it would fire while typing")
            }
            self.needsDisplay = true
            self.onChange()
            return nil
        }
    }

    private func stop() {
        listening = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
