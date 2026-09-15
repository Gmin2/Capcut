import AppKit

/// A teleprompter that floats just under the camera, so reading the script
/// keeps your eyes near the lens. It scrolls on its own while recording and
/// is never part of a screen capture.
public final class Prompter: NSObject {
    public static let shared = Prompter()

    private var panel: NSPanel?
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let playButton = TransportButton(.play, prominent: true)
    private let speedLabel = Theme.label("", .meta, color: Theme.textSecondary)
    private let editButton = FillButton("Edit")
    private var timer: Timer?
    private var editing = false

    private var script: String {
        get { UserDefaults.standard.string(forKey: "prompter.script") ?? Prompter.sample }
        set { UserDefaults.standard.set(newValue, forKey: "prompter.script") }
    }

    private var speed: Double {
        get { UserDefaults.standard.object(forKey: "prompter.speed") as? Double ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "prompter.speed") }
    }

    private var fontSize: CGFloat {
        get { UserDefaults.standard.object(forKey: "prompter.size") as? CGFloat ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "prompter.size") }
    }

    private static let sample = """
        Part 1
        ▎ Paste your script with Edit. Lines starting with ▎ are what you say, \
        anything else shows small, as a note to yourself.
        """

    public var isVisible: Bool { panel?.isVisible ?? false }
    public var isScrolling: Bool { timer != nil }

    public func toggle() {
        isVisible ? hide() : show()
    }

    public func show() {
        if panel == nil { build() }
        render()
        place()
        panel?.orderFrontRegardless()
    }

    public func hide() {
        pause()
        panel?.orderOut(nil)
    }

    /// Called when a take starts rolling.
    public func recordingStarted() {
        guard isVisible, !editing else { return }
        play()
    }

    public func recordingStopped() {
        pause()
    }

    func snapshot(to url: URL) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        Log.line("prompter snapshot \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }

    // MARK: building

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
                        styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.minSize = NSSize(width: 420, height: 200)
        // always dark: light text on dark reads best at a glance, in either theme
        p.appearance = NSAppearance(named: .darkAqua)
        // belt and braces with the recorder's own exclusion
        p.sharingType = .none

        let root = Surface(NSColor(white: 0.08, alpha: 0.94), radius: 0)
        p.contentView = root

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = text
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = false
        text.textContainerInset = NSSize(width: 28, height: 28)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.insertionPointColor = .white

        // soft fades top and bottom, with the reading line near the top where the camera is
        let fade = FadeOverlay()

        playButton.onClick = { [weak self] in
            guard let self else { return }
            self.isScrolling ? self.pause() : self.play()
        }
        let top = FillButton("Top") { [weak self] in self?.rewind() }
        top.transparent = true
        let slower = FillButton("−") { [weak self] in self?.nudgeSpeed(-0.25) }
        let faster = FillButton("+") { [weak self] in self?.nudgeSpeed(0.25) }
        let smaller = FillButton("A−") { [weak self] in self?.nudgeSize(-2) }
        let bigger = FillButton("A+") { [weak self] in self?.nudgeSize(2) }
        editButton.onClick = { [weak self] in self?.toggleEdit() }
        let close = FillButton("Hide") { [weak self] in self?.hide() }
        for b in [slower, faster, smaller, bigger, close] { b.transparent = true }

        let bar = NSStackView(views: [top, playButton, slower, speedLabel, faster, smaller, bigger, editButton, close])
        bar.spacing = 6
        bar.setCustomSpacing(14, after: playButton)
        bar.setCustomSpacing(14, after: faster)
        bar.setCustomSpacing(14, after: bigger)

        for v in [scroll, fade, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            fade.topAnchor.constraint(equalTo: scroll.topAnchor),
            fade.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            fade.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            bar.heightAnchor.constraint(equalToConstant: 32),
            speedLabel.widthAnchor.constraint(equalToConstant: 34),
        ])
        panel = p
        updateSpeedLabel()
    }

    /// Top centre of the screen with the camera, as close to the lens as it gets.
    private func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let w = min(panel.frame.width, area.width - 40)
        panel.setFrame(NSRect(x: area.midX - w / 2, y: area.maxY - panel.frame.height - 8,
                              width: w, height: panel.frame.height), display: true)
    }

    // MARK: text

    private func render() {
        guard !editing else { return }
        text.textStorage?.setAttributedString(Prompter.styled(script, size: fontSize))
    }

    /// Lines marked with ▎ are spoken and set large. Everything else is a cue
    /// ("Part 2", "the film plays here") and stays small and quiet.
    static func styled(_ script: String, size: CGFloat) -> NSAttributedString {
        let marked = script.contains("▎")
        let out = NSMutableAttributedString()
        let spoken = NSMutableParagraphStyle()
        spoken.lineSpacing = size * 0.3
        spoken.paragraphSpacing = size * 0.5
        let cue = NSMutableParagraphStyle()
        cue.paragraphSpacingBefore = size * 0.6
        cue.paragraphSpacing = size * 0.35

        for raw in script.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isSpoken = !marked || line.hasPrefix("▎")
            let body = line.drop(while: { $0 == "▎" || $0 == " " })
            guard !body.isEmpty else { continue }
            let attrs: [NSAttributedString.Key: Any] = isSpoken
                ? [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                   .foregroundColor: NSColor.white, .paragraphStyle: spoken]
                : [.font: NSFont.systemFont(ofSize: max(13, size * 0.45), weight: .semibold),
                   .foregroundColor: NSColor(srgbRed: 1, green: 0.67, blue: 0, alpha: 0.9),
                   .paragraphStyle: cue]
            out.append(NSAttributedString(string: body + "\n", attributes: attrs))
        }
        // room after the last line, so it can scroll all the way up to the camera
        let tail = NSMutableParagraphStyle()
        tail.minimumLineHeight = 400
        out.append(NSAttributedString(string: " ", attributes: [.paragraphStyle: tail]))
        return out
    }

    private func toggleEdit() {
        editing.toggle()
        if editing {
            pause()
            text.isEditable = true
            text.isSelectable = true
            text.textStorage?.setAttributedString(NSAttributedString(string: script, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.white,
            ]))
            editButton.title = "Done"
            // a non activating panel only takes typing once asked
            panel?.makeKey()
            panel?.makeFirstResponder(text)
        } else {
            script = text.string
            text.isEditable = false
            text.isSelectable = false
            editButton.title = "Edit"
            render()
            rewind()
        }
    }

    // MARK: scrolling

    private func play() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        playButton.glyph = .pause
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        playButton.glyph = .play
    }

    private func rewind() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func step() {
        let clip = scroll.contentView
        let maxY = max(0, text.frame.height - clip.bounds.height)
        // tuned by eye to talking pace, roughly a line every three seconds at 1×
        var origin = clip.bounds.origin
        origin.y = min(origin.y + CGFloat(speed * 28.0 / 60.0) * fontSize / 30, maxY)
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        if origin.y >= maxY { pause() }
    }

    private func nudgeSpeed(_ d: Double) {
        speed = min(max(speed + d, 0.25), 4)
        updateSpeedLabel()
    }

    private func nudgeSize(_ d: CGFloat) {
        fontSize = min(max(fontSize + d, 16), 64)
        render()
    }

    private func updateSpeedLabel() {
        speedLabel.stringValue = String(format: "%.2g×", speed)
        speedLabel.alignment = .center
    }
}

/// Fades the text in at the top and out at the bottom of the prompter.
private final class FadeOverlay: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        let bg = NSColor(white: 0.08, alpha: 0.94)
        let h = min(60, bounds.height / 4)
        NSGradient(starting: bg, ending: bg.withAlphaComponent(0))?
            .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: h), angle: 90)
        NSGradient(starting: bg.withAlphaComponent(0), ending: bg)?
            .draw(in: NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h), angle: 90)
    }
}
