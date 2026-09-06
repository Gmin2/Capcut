import AppKit

/// The properties panel.
///
/// Everything here already exists in project.json; this is about not having to
/// open a text editor to change a number. Each control writes straight back
/// through the same save path the timeline uses, so there is one way an edit
/// happens regardless of where it came from.
public final class InspectorView: NSView {

    public var onEdit: ((inout Project) -> Void)? {
        didSet { }
    }
    /// Called with a mutation to apply and save.
    public var apply: ((@escaping (inout Project) -> Void) -> Void)?

    private let stack = NSStackView()
    private var project: Project?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public func show(_ p: Project) {
        project = p
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        section("Background")
        row(popup(["midnight", "slate", "ember", "forest", "paper", "ink", "screen"],
                  selected: p.backgroundPreset ?? "midnight") { [weak self] name in
            self?.apply? { $0.backgroundPreset = name; $0.style.background = Style.presets[name] ?? $0.style.background }
        })

        section("Frame")
        row(popup(["none", "macWindow", "browser"],
                  selected: p.deviceFrame.rawValue) { [weak self] name in
            self?.apply? { $0.deviceFrame = DeviceFrame(rawValue: name) ?? .none }
        })

        section("Camera")
        scrub("Cursor size", p.cursor.scale, 0.8...3.0, 0.1) { $0.cursor.scale = $1 }
        scrub("Smoothing", p.cursor.smoothing, 0...0.9, 0.05) { $0.cursor.smoothing = $1 }
        scrub("Motion blur", p.motionBlur, 0...2, 0.05) { $0.motionBlur = $1 }

        section("Trim")
        scrub("Start", p.trimStart, 0...600, 0.1) { $0.trimStart = $1 }

        section("Captions")
        toggle("Show captions", p.captions.enabled) { $0.captions.enabled = $1 }
        scrub("Words per line", Double(p.captions.wordsPerCue), 2...8, 1) {
            $0.captions.wordsPerCue = Int($1)
        }
        scrub("Text size", p.captions.fontSize, 20...90, 2) { $0.captions.fontSize = $1 }

        section("Keys")
        toggle("Show keystrokes", p.keycast.visible) { $0.keycast.visible = $1 }

        section("Audio")
        scrub("Voice", p.audio.mic, 0...2, 0.05) { $0.audio.mic = $1 }
        scrub("System", p.audio.system, 0...2, 0.05) { $0.audio.system = $1 }
        toggle("Duck under voice", p.audio.duckSystemUnderVoice) {
            $0.audio.duckSystemUnderVoice = $1
        }
    }

    // MARK: building blocks

    private func section(_ title: String) {
        let label = Theme.caption(title)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(label)
    }

    private func row(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -26).isActive = true
    }

    private func scrub(_ name: String, _ value: Double, _ range: ClosedRange<Double>,
                       _ step: Double,
                       _ set: @escaping (inout Project, Double) -> Void) {
        let f = ScrubField(name, value: value, range: range, step: step)
        f.onChange = { [weak self] v in self?.apply? { set(&$0, v) } }
        row(f)
    }

    private func toggle(_ name: String, _ on: Bool,
                        _ set: @escaping (inout Project, Bool) -> Void) {
        let b = NSButton(checkboxWithTitle: name, target: nil, action: nil)
        b.state = on ? .on : .off
        b.font = .systemFont(ofSize: 11)
        b.contentTintColor = Theme.accent
        b.attributedTitle = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: Theme.text,
        ])
        let handler = ToggleHandler { [weak self] isOn in
            self?.apply? { set(&$0, isOn) }
        }
        b.target = handler
        b.action = #selector(ToggleHandler.fired(_:))
        handlers.append(handler)
        row(b)
    }

    private func popup(_ options: [String], selected: String,
                       _ set: @escaping (String) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: options)
        p.selectItem(withTitle: selected)
        p.font = .systemFont(ofSize: 11)
        let handler = PopupHandler { set($0) }
        p.target = handler
        p.action = #selector(PopupHandler.fired(_:))
        handlers.append(handler)
        return p
    }

    /// AppKit targets are unowned, so the small closure wrappers have to be
    /// kept alive by the panel itself.
    private var handlers: [AnyObject] = []
}

final class ToggleHandler: NSObject {
    private let body: (Bool) -> Void
    init(_ body: @escaping (Bool) -> Void) { self.body = body }
    @objc func fired(_ sender: NSButton) { body(sender.state == .on) }
}

final class PopupHandler: NSObject {
    private let body: (String) -> Void
    init(_ body: @escaping (String) -> Void) { self.body = body }
    @objc func fired(_ sender: NSPopUpButton) { body(sender.titleOfSelectedItem ?? "") }
}
