import AppKit
import AVFoundation
import ScreenCaptureKit

/// The first run.
///
/// Every part of this app needs a permission macOS only grants on request, and
/// a recorder that silently records nothing is the worst way to find that out.
/// So the first launch asks for them in the order they are needed, shows what
/// each one is for, and does not pretend a refusal did not happen.
@MainActor
public final class Welcome: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private static var shared: Welcome?

    private let window: NSWindow
    private var rows: [PermissionStep] = []
    private let continueButton = FillButton("Start using Cutaway")
    private var onFinish: (() -> Void)?

    /// True until the first run has been seen through.
    public static var needed: Bool {
        !UserDefaults.standard.bool(forKey: "welcome.done")
    }

    public static func show(onFinish: (() -> Void)? = nil) {
        if let shared {
            shared.window.makeKeyAndOrderFront(nil)
            return
        }
        shared = Welcome(onFinish: onFinish)
    }

    static var isOpen: Bool { shared != nil }

    private init(onFinish: (() -> Void)?) {
        self.onFinish = onFinish
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome"
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
        let title = Theme.label("Welcome to Cutaway", .title)
        let blurb = Theme.label("Record a demo, capture a screenshot, mark it up, ship the video.\n"
                                + "macOS needs to let us in first. Each one is asked for once.",
                                .body, color: Theme.textSecondary)
        blurb.maximumNumberOfLines = 3
        blurb.lineBreakMode = .byWordWrapping
        blurb.preferredMaxLayoutWidth = 440

        let stack = NSStackView(views: [title, blurb])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(22, after: blurb)

        for step in PermissionStep.Kind.allCases {
            let row = PermissionStep(kind: step) { [weak self] in self?.refresh() }
            rows.append(row)
            stack.addArrangedSubview(row)
        }

        let skip = FillButton("Not now") { [weak self] in self?.finish() }
        skip.transparent = true
        continueButton.onClick = { [weak self] in self?.finish() }
        let buttons = NSStackView(views: [skip, continueButton])
        buttons.spacing = 10
        stack.setCustomSpacing(26, after: rows.last ?? blurb)
        stack.addArrangedSubview(buttons)

        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -34),
            continueButton.heightAnchor.constraint(equalToConstant: 32),
            skip.heightAnchor.constraint(equalToConstant: 32),
        ])
        return root
    }

    func refresh() {
        rows.forEach { $0.refresh() }
        let missing = PermissionStep.Kind.allCases.filter { !$0.granted && $0.required }
        continueButton.title = missing.isEmpty ? "Start using Cutaway" : "Continue anyway"
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "welcome.done")
        window.close()
        onFinish?()
    }

    public func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "welcome.done")
        Welcome.shared = nil
    }
}

/// One permission: what it is for, whether it is granted, and a button that
/// actually asks for it rather than sending you to a settings pane to hunt.
final class PermissionStep: ThemedView {
    enum Kind: CaseIterable {
        case screen, microphone, camera

        var title: String {
            switch self {
            case .screen: return "Screen recording"
            case .microphone: return "Microphone"
            case .camera: return "Camera"
            }
        }

        var why: String {
            switch self {
            case .screen: return "to record your screen and take captures"
            case .microphone: return "to record what you say"
            case .camera: return "for the facecam and camera only takes"
            }
        }

        var icon: Icon {
            switch self {
            case .screen: return .display
            case .microphone: return .mic
            case .camera: return .camera
            }
        }

        /// Without screen recording there is no product at all; the other two
        /// are worth having but a screenshot works without them.
        var required: Bool { self == .screen }

        var granted: Bool {
            switch self {
            case .screen: return CGPreflightScreenCaptureAccess()
            case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            }
        }

        @MainActor
        func request(then: @escaping () -> Void) {
            switch self {
            case .screen:
                // the system prompt only appears once per app; afterwards this
                // opens the pane instead, which is the only way back
                if CGPreflightScreenCaptureAccess() {
                    then()
                } else if CGRequestScreenCaptureAccess() {
                    then()
                } else {
                    openSettings("Privacy_ScreenCapture")
                    then()
                }
            case .microphone:
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { then() }
                }
            case .camera:
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    DispatchQueue.main.async { then() }
                }
            }
        }

        func openSettings(_ pane: String) {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
            if let url { NSWorkspace.shared.open(url) }
        }
    }

    private let kind: Kind
    private let onChange: () -> Void
    private let status = Theme.label("", .meta, color: Theme.textSecondary)
    private let button = FillButton("Allow")

    init(kind: Kind, onChange: @escaping () -> Void) {
        self.kind = kind
        self.onChange = onChange
        super.init(frame: .zero)

        let title = Theme.label(kind.title, .bodyStrong)
        let why = Theme.label(kind.why, .meta, color: Theme.textTertiary)
        let text = NSStackView(views: [title, why])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        button.onClick = { [weak self] in
            guard let self else { return }
            self.kind.request { self.onChange() }
        }

        let icon = IconBadge(icon: kind.icon)
        let line = NSStackView(views: [icon, text, status, button])
        line.spacing = 12
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            text.widthAnchor.constraint(equalToConstant: 230),
            status.widthAnchor.constraint(equalToConstant: 60),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let ok = kind.granted
        status.stringValue = ok ? "granted" : ""
        button.isHidden = ok
        button.title = "Allow"
    }
}

/// The icon in a soft square, so the list reads as steps rather than rows.
final class IconBadge: ThemedView {
    private let icon: Icon

    init(icon: Icon) {
        self.icon = icon
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        Theme.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusCard, yRadius: Theme.radiusCard).fill()
        icon.draw(in: NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18),
                  color: Theme.icon)
    }
}
