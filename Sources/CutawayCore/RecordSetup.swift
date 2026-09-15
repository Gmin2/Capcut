import AppKit
import AVFoundation
import ScreenCaptureKit

/// What the next recording captures. Kept in user defaults so the setup screen
/// opens the way it was left, and so the hotkey records the same thing.
public struct RecordSettings {
    public enum Capture: String, CaseIterable {
        case display = "Display", window = "Window", area = "Area", camera = "Camera only"
    }

    public var capture = Capture.display
    public var displayID: CGDirectDisplayID?
    /// Bundle id of the app to record in window mode.
    public var app: String?
    /// Fraction of the display, origin top left.
    public var area = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
    public var mic = true
    public var camera = true
    public var cameraID: String?
    /// Level system audio starts at in the edit. Zero does not record it.
    public var desktopAudio = 0.55
    public var countdown = 3
    public var keystrokes = false

    public static func load() -> RecordSettings {
        let d = UserDefaults.standard
        var s = RecordSettings()
        if let c = d.string(forKey: "rec.capture").flatMap(Capture.init) { s.capture = c }
        if let id = d.object(forKey: "rec.display") as? Int { s.displayID = CGDirectDisplayID(id) }
        s.app = d.string(forKey: "rec.app")
        if let a = d.array(forKey: "rec.area") as? [Double], a.count == 4 {
            s.area = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        s.mic = d.object(forKey: "rec.mic") as? Bool ?? s.mic
        s.camera = d.object(forKey: "rec.camera") as? Bool ?? s.camera
        s.cameraID = d.string(forKey: "rec.cameraID")
        s.desktopAudio = d.object(forKey: "rec.desktopAudio") as? Double ?? s.desktopAudio
        s.countdown = d.object(forKey: "rec.countdown") as? Int ?? s.countdown
        s.keystrokes = d.bool(forKey: "rec.keys")
        return s
    }

    public func save() {
        let d = UserDefaults.standard
        d.set(capture.rawValue, forKey: "rec.capture")
        d.set(displayID.map { Int($0) }, forKey: "rec.display")
        d.set(app, forKey: "rec.app")
        d.set([area.minX, area.minY, area.width, area.height], forKey: "rec.area")
        d.set(mic, forKey: "rec.mic")
        d.set(camera, forKey: "rec.camera")
        d.set(cameraID, forKey: "rec.cameraID")
        d.set(desktopAudio, forKey: "rec.desktopAudio")
        d.set(countdown, forKey: "rec.countdown")
        d.set(keystrokes, forKey: "rec.keys")
    }

    /// The area in display points, for the recorder.
    func areaPoints(of display: CGDirectDisplayID) -> CGRect {
        let size = CGDisplayBounds(display).size
        return CGRect(x: area.minX * size.width, y: area.minY * size.height,
                      width: area.width * size.width, height: area.height * size.height)
    }
}

/// Something that can be recorded: a whole display, one app's windows, or a camera.
struct Source {
    enum Kind: Equatable {
        case display(CGDirectDisplayID)
        case app(String)
        case camera(String)
    }

    let kind: Kind
    let name: String
    let detail: String
    let size: CGSize
    let filter: SCContentFilter?
    let icon: NSImage?

    // system surfaces that show up as windows but are not worth recording alone
    private static let skipped: Set<String> = [
        "com.apple.dock", "com.apple.controlcenter", "com.apple.WindowManager",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.systemuiserver",
    ]

    static func all() async throws -> [Source] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = Bundle.main.bundleIdentifier ?? "com.mintu.cutaway"
        // matched by process, not bundle id: the app list does not always carry ours
        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
        var out: [Source] = []

        for (i, d) in content.displays.enumerated() {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID
            }
            out.append(Source(kind: .display(d.displayID),
                              name: screen?.localizedName ?? "Display \(i + 1)",
                              detail: "\(d.width) × \(d.height)",
                              size: CGSize(width: d.width, height: d.height),
                              filter: SCContentFilter(display: d, excludingWindows: mine),
                              icon: nil))
        }

        // one card per app, pictured by its biggest window, since window mode
        // records every window the app has open
        var biggest: [String: SCWindow] = [:]
        for w in content.windows where w.windowLayer == 0 && w.frame.width >= 240 && w.frame.height >= 160 {
            guard let id = w.owningApplication?.bundleIdentifier, !id.isEmpty, id != me,
                  !skipped.contains(id) else { continue }
            if let b = biggest[id], b.frame.width * b.frame.height >= w.frame.width * w.frame.height { continue }
            biggest[id] = w
        }
        let apps = biggest.sorted {
            ($0.value.owningApplication?.applicationName ?? "") < ($1.value.owningApplication?.applicationName ?? "")
        }
        for (id, w) in apps {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            out.append(Source(kind: .app(id),
                              name: w.owningApplication?.applicationName ?? id,
                              detail: w.title?.isEmpty == false ? w.title! : "\(Int(w.frame.width)) × \(Int(w.frame.height))",
                              size: w.frame.size,
                              filter: SCContentFilter(desktopIndependentWindow: w),
                              icon: icon))
        }
        return out
    }

    static func camera(_ device: AVCaptureDevice) -> Source {
        Source(kind: .camera(device.uniqueID), name: device.localizedName, detail: "fills the whole video",
               size: CGSize(width: 1920, height: 1080), filter: nil, icon: nil)
    }

    func image(width: CGFloat) async -> CGImage? {
        guard let filter, size.width > 0 else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(width)
        config.height = Int(width * size.height / size.width)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - setup screen

/// Pick a source, frame it, set the inputs, start. Shown in place of the
/// editor while a new take is being set up.
public final class RecordSetupView: ThemedView {
    public var onStart: ((_ countdown: Bool) -> Void)?
    public var onClose: (() -> Void)?

    public let startButton = FillButton("Start Recording")
    private var settings = RecordSettings.load()
    private var sources: [Source] = []

    private let cards = FlippedStack()
    private let canvas = AreaCanvas()
    private let facecam = Facecam()
    private let sourceHint = Theme.label("", .meta, color: Theme.textTertiary)
    private let micButton = FillButton("Mic On", icon: .mic)
    private let cameraSwitch = Switch(true)
    private let cameraMenu = Dropdown(["No camera"], selected: "No camera")
    private let captureMenu = Dropdown(RecordSettings.Capture.allCases.map(\.rawValue), selected: "Display")
    private let desktopAudio = SliderPill("Desktop Audio", value: 0.55)
    private var cameras: [AVCaptureDevice] = []
    private var timer: Timer?
    private var capturing = false
    private var bubbleConstraints: [NSLayoutConstraint] = []
    private var fullConstraints: [NSLayoutConstraint] = []

    public override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirty: NSRect) {
        Theme.canvas.setFill()
        bounds.fill()
    }

    private func build() {
        let title = Theme.label("New Recording", .title)
        let subtitle = Theme.label("Pick what to record, frame it, then start. ⌘⇧8 starts and stops from anywhere.",
                                   .meta, color: Theme.textSecondary)
        let close = FillButton("Back to editor", icon: .chevronLeft) { [weak self] in self?.onClose?() }
        close.transparent = true

        let sourceHeader = SectionHeader("Source", icon: .display)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        // no visible scroller: with a mouse attached macOS uses the legacy
        // style, which takes space from the cards and clips them
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        cards.orientation = .horizontal
        cards.spacing = 10
        cards.alignment = .top
        cards.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = cards

        let previewCard = Surface(Theme.inset)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(canvas)
        facecam.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(facecam)
        canvas.onAreaChange = { [weak self] area in
            self?.settings.area = area
            self?.settings.save()
        }

        let bar = buildBar()

        // a corner bubble over the screen, or the whole preview in camera only mode
        bubbleConstraints = [
            facecam.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -28),
            facecam.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -28),
            facecam.widthAnchor.constraint(equalTo: previewCard.widthAnchor, multiplier: 0.2),
            facecam.heightAnchor.constraint(equalTo: facecam.widthAnchor, multiplier: 0.75),
        ]
        let fill = facecam.widthAnchor.constraint(equalTo: previewCard.widthAnchor, constant: -32)
        // below the window's own size priority, or filling the width grows the window
        fill.priority = .defaultLow
        fullConstraints = [
            facecam.centerXAnchor.constraint(equalTo: previewCard.centerXAnchor),
            facecam.centerYAnchor.constraint(equalTo: previewCard.centerYAnchor),
            facecam.widthAnchor.constraint(lessThanOrEqualTo: previewCard.widthAnchor, constant: -32),
            facecam.heightAnchor.constraint(lessThanOrEqualTo: previewCard.heightAnchor, constant: -32),
            facecam.heightAnchor.constraint(equalTo: facecam.widthAnchor, multiplier: 9.0 / 16.0),
            fill,
        ]
        NSLayoutConstraint.activate(bubbleConstraints)

        for v in [title, subtitle, close, sourceHeader, sourceHint, scroll, previewCard, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -16),
            close.centerYAnchor.constraint(equalTo: title.bottomAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            sourceHeader.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22),
            sourceHeader.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sourceHeader.widthAnchor.constraint(equalToConstant: 120),
            sourceHint.centerYAnchor.constraint(equalTo: sourceHeader.centerYAnchor),
            sourceHint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            scroll.topAnchor.constraint(equalTo: sourceHeader.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scroll.heightAnchor.constraint(equalToConstant: SourceCard.size.height),
            cards.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            cards.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),

            previewCard.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            previewCard.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            previewCard.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: previewCard.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),

            bar.topAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: 16),
            bar.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    private func buildBar() -> NSView {
        let bar = Surface(Theme.panel)

        startButton.showsDot = true
        startButton.trailingChevron = true
        startButton.onClick = { [weak self] in self?.onStart?(true) }
        startButton.onChevron = { [weak self] in self?.showStartMenu() }

        micButton.onClick = { [weak self] in
            guard let self else { return }
            self.settings.mic.toggle()
            self.settings.save()
            self.syncControls()
        }
        cameraSwitch.onChange = { [weak self] on in
            // camera only has nothing to show without it
            guard self?.settings.capture != .camera else {
                self?.cameraSwitch.isOn = true
                return
            }
            self?.settings.camera = on
            self?.settings.save()
            self?.syncControls()
            self?.updateFacecam()
        }
        cameraMenu.onChange = { [weak self] name in
            guard let self else { return }
            self.settings.cameraID = self.cameras.first { $0.localizedName == name }?.uniqueID
            self.settings.save()
            self.updateFacecam()
            if self.settings.capture == .camera { self.rebuildCards() }
        }
        let settingsButton = FillButton("Settings", icon: .gear)
        settingsButton.onClick = { [weak self, weak settingsButton] in
            guard let self, let settingsButton else { return }
            self.showSettingsMenu(from: settingsButton)
        }

        captureMenu.onChange = { [weak self] value in
            guard let self, let c = RecordSettings.Capture(rawValue: value) else { return }
            self.settings.capture = c
            self.settings.save()
            self.syncControls()
            self.updateFacecam()
            self.rebuildCards()
            self.refreshPreview()
        }
        desktopAudio.onChange = { [weak self] v in
            self?.settings.desktopAudio = v
            self?.settings.save()
        }

        let cameraLabel = Theme.label("Camera:", .body, color: Theme.textSecondary)
        let row1 = NSStackView(views: [startButton, micButton, cameraLabel, cameraSwitch, cameraMenu, settingsButton])
        row1.spacing = 12
        row1.setCustomSpacing(8, after: cameraLabel)
        row1.setCustomSpacing(10, after: cameraSwitch)
        row1.setCustomSpacing(20, after: startButton)
        row1.setCustomSpacing(20, after: cameraMenu)

        let captureLabel = Theme.label("Capture:", .body, color: Theme.textSecondary)
        let row2 = NSStackView(views: [captureLabel, captureMenu, desktopAudio])
        row2.spacing = 8
        row2.setCustomSpacing(20, after: captureMenu)

        let rule = Divider()
        for v in [row1, row2, rule] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        for v in [startButton, micButton, cameraMenu, settingsButton, captureMenu] as [NSView] {
            v.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        NSLayoutConstraint.activate([
            row1.topAnchor.constraint(equalTo: bar.topAnchor, constant: 14),
            row1.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            row1.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -14),
            rule.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            rule.heightAnchor.constraint(equalToConstant: 1),
            row2.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 10),
            row2.leadingAnchor.constraint(equalTo: row1.leadingAnchor),
            row2.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -12),
            desktopAudio.widthAnchor.constraint(equalToConstant: 300),
            desktopAudio.heightAnchor.constraint(equalToConstant: 30),
        ])
        return bar
    }

    // MARK: lifecycle

    /// Called when the screen is shown: rereads devices and sources, and keeps
    /// the preview live until `deactivate`.
    public func activate() {
        settings = RecordSettings.load()
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        syncControls()
        updateFacecam()
        Task { @MainActor in
            do {
                self.sources = try await Source.all()
            } catch {
                Log.line("could not list sources: \(error.localizedDescription)")
                self.sources = []
            }
            self.rebuildCards()
            self.refreshPreview()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPreview() }
        }
    }

    public func deactivate() {
        timer?.invalidate()
        timer = nil
        // the recorder needs the camera to itself
        facecam.stop()
    }

    private func updateFacecam() {
        let full = settings.capture == .camera
        NSLayoutConstraint.deactivate(full ? bubbleConstraints : fullConstraints)
        NSLayoutConstraint.activate(full ? fullConstraints : bubbleConstraints)
        facecam.cornerRadius = full ? 10 : 14
        if settings.camera || full, !cameras.isEmpty {
            facecam.start(deviceID: settings.cameraID)
        } else {
            facecam.stop()
        }
    }

    public func setRecording(_ live: Bool) {
        startButton.title = live ? "Stop Recording" : "Start Recording"
        startButton.trailingChevron = !live
    }

    private func syncControls() {
        micButton.title = settings.mic ? "Mic On" : "Mic Off"
        micButton.icon = settings.mic ? .mic : .micOff
        let cameraOnly = settings.capture == .camera
        cameraSwitch.isOn = settings.camera || cameraOnly
        cameraSwitch.isEnabled = !cameraOnly
        let names = cameras.map(\.localizedName)
        cameraMenu.options = names.isEmpty ? ["No camera"] : names
        cameraMenu.selected = cameras.first { $0.uniqueID == settings.cameraID }?.localizedName
            ?? names.first ?? "No camera"
        cameraMenu.isEnabled = (settings.camera || cameraOnly) && !names.isEmpty
        captureMenu.selected = settings.capture.rawValue
        desktopAudio.value = settings.desktopAudio
        desktopAudio.isHidden = cameraOnly
        canvas.showsArea = settings.capture == .area
        canvas.placeholder = cameraOnly ? (cameras.isEmpty ? "No camera found" : "") : "Pick a source to see it here"
        if cameraOnly { canvas.image = nil }
        canvas.area = settings.area
    }

    // MARK: sources

    private var visibleSources: [Source] {
        if settings.capture == .camera { return cameras.map(Source.camera) }
        return sources.filter {
            if case .app = $0.kind { return settings.capture == .window }
            return settings.capture != .window
        }
    }

    private var selectedSource: Source? {
        let list = visibleSources
        return list.first {
            switch $0.kind {
            case .display(let id): return id == settings.displayID
            case .app(let id): return id == settings.app
            case .camera(let id): return id == settings.cameraID
            }
        } ?? list.first
    }

    private func rebuildCards() {
        cards.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let list = visibleSources
        let chosen = selectedSource?.kind
        for source in list {
            let card = SourceCard(source)
            card.selected = source.kind == chosen
            card.onClick = { [weak self] in self?.select(source) }
            cards.addArrangedSubview(card)
            Task { @MainActor in card.thumbnail = await source.image(width: 360) }
        }
        let noun = ["Window": "app", "Camera only": "camera"][settings.capture.rawValue] ?? "display"
        sourceHint.stringValue = list.isEmpty
            ? "no \(noun)s found"
            : "\(list.count) \(noun)\(list.count == 1 ? "" : "s")"
        cards.layoutSubtreeIfNeeded()
    }

    private func select(_ source: Source) {
        switch source.kind {
        case .display(let id): settings.displayID = id
        case .app(let id): settings.app = id
        case .camera(let id):
            settings.cameraID = id
            syncControls()
            updateFacecam()
        }
        settings.save()
        for case let card as SourceCard in cards.arrangedSubviews {
            card.selected = card.source.kind == source.kind
        }
        refreshPreview()
    }

    private func refreshPreview() {
        guard !capturing, window != nil, !isHiddenOrHasHiddenAncestor, settings.capture != .camera else { return }
        guard let source = selectedSource else {
            canvas.image = nil
            return
        }
        capturing = true
        canvas.sourceSize = source.size
        let width = min(max(canvas.bounds.width * 2, 800), 2000)
        Task { @MainActor in
            let image = await source.image(width: width)
            self.capturing = false
            if self.selectedSource?.kind == source.kind { self.canvas.image = image }
        }
    }

    // MARK: menus

    private func showStartMenu() {
        let menu = NSMenu()
        let now = NSMenuItem(title: "Start without countdown", action: #selector(startNow), keyEquivalent: "")
        now.target = self
        menu.addItem(now)
        menu.addItem(.separator())
        addCountdownItems(to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: startButton.bounds.height + 4), in: startButton)
    }

    private func showSettingsMenu(from button: NSView) {
        let menu = NSMenu()
        let keys = NSMenuItem(title: "Record keystrokes", action: #selector(toggleKeys), keyEquivalent: "")
        keys.target = self
        keys.state = settings.keystrokes ? .on : .off
        menu.addItem(keys)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Countdown", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        addCountdownItems(to: menu)
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Show recordings in Finder", action: #selector(showFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func addCountdownItems(to menu: NSMenu) {
        for seconds in [0, 3, 5, 10] {
            let item = NSMenuItem(title: seconds == 0 ? "No countdown" : "\(seconds) second countdown",
                                  action: #selector(pickCountdown(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = settings.countdown == seconds ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func startNow() { onStart?(false) }

    @objc private func pickCountdown(_ item: NSMenuItem) {
        settings.countdown = item.tag
        settings.save()
    }

    @objc private func toggleKeys() {
        settings.keystrokes.toggle()
        settings.save()
    }

    @objc private func showFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.recordingsRoot])
    }
}

// MARK: - pieces

/// A source to pick: a live thumbnail, its name, a line of detail.
final class SourceCard: Control {
    static let size = NSSize(width: 184, height: 136)

    let source: Source
    var selected = false { didSet { needsDisplay = true } }
    var thumbnail: CGImage? { didSet { needsDisplay = true } }

    init(_ source: Source) {
        self.source = source
        super.init(frame: NSRect(origin: .zero, size: SourceCard.size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: SourceCard.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: SourceCard.size.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                xRadius: Theme.radiusCard, yRadius: Theme.radiusCard)
        (selected ? Theme.fillSelected : hovering ? Theme.fillHover : Theme.inset).setFill()
        card.fill()
        if selected {
            card.lineWidth = Theme.borderSelected
            Theme.cardOutline.setStroke()
            card.stroke()
        }

        let shot = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 84)
        let clip = NSBezierPath(roundedRect: shot, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        Theme.badge.setFill()
        shot.fill()
        if let thumbnail {
            // fill the frame, cropping whichever side is too long
            let img = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            let s = max(shot.width / img.size.width, shot.height / img.size.height)
            let w = img.size.width * s, h = img.size.height * s
            img.draw(in: NSRect(x: shot.midX - w / 2, y: shot.midY - h / 2, width: w, height: h),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if thumbnail == nil, case .camera = source.kind {
            Icon.camera.draw(in: NSRect(x: shot.midX - 14, y: shot.midY - 14, width: 28, height: 28),
                             color: Theme.textTertiary)
        }
        NSGraphicsContext.restoreGraphicsState()

        var x: CGFloat = 10
        if let icon = source.icon {
            icon.draw(in: NSRect(x: x, y: 100, width: 16, height: 16), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 21
        } else if case .display = source.kind {
            Icon.display.draw(in: NSRect(x: x, y: 101, width: 14, height: 14), color: Theme.icon)
            x += 20
        } else if case .camera = source.kind {
            Icon.camera.draw(in: NSRect(x: x, y: 101, width: 14, height: 14), color: Theme.icon)
            x += 20
        }
        draw(source.name, in: NSRect(x: x, y: 99, width: bounds.width - x - 10, height: 18),
             font: Theme.Text.body.font, color: Theme.textPrimary)
        draw(source.detail, in: NSRect(x: 10, y: 117, width: bounds.width - 20, height: 16),
             font: Theme.Text.meta.font, color: Theme.textTertiary)
    }

    private func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}

/// The big preview. In area mode it carries the selection: drag inside to
/// move it, drag a handle to resize, drag anywhere else to draw a new one.
final class AreaCanvas: ThemedView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var sourceSize = CGSize(width: 1920, height: 1080)
    var showsArea = false { didSet { needsDisplay = true } }
    var area = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7) { didSet { needsDisplay = true } }
    var onAreaChange: ((CGRect) -> Void)?
    var placeholder = "Pick a source to see it here" { didSet { needsDisplay = true } }

    private enum Grab { case move(CGPoint), handle(Int), draw(CGPoint) }
    private var grab: Grab?
    private let minFraction: CGFloat = 0.06

    /// Where the picture sits, fitted inside the card.
    private var imageRect: NSRect {
        let box = bounds.insetBy(dx: 16, dy: 16)
        let aspect = image.map { CGFloat($0.width) / CGFloat($0.height) }
            ?? sourceSize.width / max(sourceSize.height, 1)
        var w = box.width, h = w / aspect
        if h > box.height { h = box.height; w = h * aspect }
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    private var areaRect: NSRect {
        let r = imageRect
        return NSRect(x: r.minX + area.minX * r.width, y: r.minY + area.minY * r.height,
                      width: area.width * r.width, height: area.height * r.height)
    }

    /// Corners then edge midpoints, clockwise from top left.
    private var handles: [NSPoint] {
        let a = areaRect
        return [NSPoint(x: a.minX, y: a.minY), NSPoint(x: a.maxX, y: a.minY),
                NSPoint(x: a.maxX, y: a.maxY), NSPoint(x: a.minX, y: a.maxY),
                NSPoint(x: a.midX, y: a.minY), NSPoint(x: a.maxX, y: a.midY),
                NSPoint(x: a.midX, y: a.maxY), NSPoint(x: a.minX, y: a.midY)]
    }

    override func draw(_ dirty: NSRect) {
        let r = imageRect
        guard let image else {
            let text = placeholder as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.body.font,
                                                        .foregroundColor: Theme.textTertiary]
            let s = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).addClip()
        NSImage(cgImage: image, size: r.size).draw(in: r, from: .zero, operation: .sourceOver,
                                                   fraction: 1, respectFlipped: true, hints: nil)
        guard showsArea else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let a = areaRect
        let shade = NSBezierPath(rect: r)
        shade.append(NSBezierPath(rect: a))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        shade.fill()
        NSGraphicsContext.restoreGraphicsState()

        let outline = NSBezierPath(rect: a)
        outline.lineWidth = Theme.borderSelected
        Theme.accent.setStroke()
        outline.stroke()

        for p in handles {
            let h = NSBezierPath(roundedRect: NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9),
                                 xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            h.fill()
            h.lineWidth = 1.5
            Theme.accent.setStroke()
            h.stroke()
        }

        let label = "\(Int(area.width * sourceSize.width)) × \(Int(area.height * sourceSize.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.caption.font, .foregroundColor: Theme.onAccent]
        let s = label.size(withAttributes: attrs)
        var tag = NSRect(x: a.minX, y: a.minY - s.height - 12, width: s.width + 12, height: s.height + 6)
        if tag.minY < r.minY + 4 { tag.origin.y = a.minY + 8; tag.origin.x = a.minX + 8 }
        Theme.accent.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: tag.minX + 6, y: tag.minY + 3), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard showsArea, image != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let i = handles.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) {
            grab = .handle(i)
        } else if areaRect.contains(p) {
            let f = fraction(p)
            grab = .move(CGPoint(x: f.x - area.minX, y: f.y - area.minY))
        } else if imageRect.contains(p) {
            grab = .draw(fraction(p))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let f = fraction(convert(event.locationInWindow, from: nil))
        switch grab {
        case .move(let offset):
            area.origin = CGPoint(x: min(max(f.x - offset.x, 0), 1 - area.width),
                                  y: min(max(f.y - offset.y, 0), 1 - area.height))
        case .draw(let start):
            area = CGRect(x: min(start.x, f.x), y: min(start.y, f.y),
                          width: max(abs(f.x - start.x), minFraction),
                          height: max(abs(f.y - start.y), minFraction)).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        case .handle(let i):
            var minX = area.minX, maxX = area.maxX, minY = area.minY, maxY = area.maxY
            if [0, 3, 7].contains(i) { minX = min(f.x, maxX - minFraction) }
            if [1, 2, 5].contains(i) { maxX = max(f.x, minX + minFraction) }
            if [0, 1, 4].contains(i) { minY = min(f.y, maxY - minFraction) }
            if [2, 3, 6].contains(i) { maxY = max(f.y, minY + minFraction) }
            area = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard grab != nil else { return }
        grab = nil
        onAreaChange?(area)
    }

    private func fraction(_ p: NSPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1),
                       y: min(max((p.y - r.minY) / r.height, 0), 1))
    }
}

/// Live camera in a bubble, so you can check framing and light before a take.
/// Mirrored, the way a mirror looks, which is what people expect of themselves.
final class Facecam: NSView {
    private var session: AVCaptureSession?
    private var deviceID: String?
    private let preview = AVCaptureVideoPreviewLayer()
    var cornerRadius: CGFloat = 14 { didSet { layer?.cornerRadius = cornerRadius } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(preview)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }

    func start(deviceID: String?) {
        if session != nil, deviceID == self.deviceID { return }
        stop()
        Task { @MainActor in
            guard await WebcamRecorder.requestAccess() else {
                Log.line("facecam: camera permission denied")
                return
            }
            let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
            guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
                Log.line("facecam: no camera to show")
                return
            }
            let session = AVCaptureSession()
            guard session.canAddInput(input) else { return }
            session.addInput(input)
            self.preview.session = session
            self.session = session
            self.deviceID = deviceID
            self.isHidden = false
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
            Log.line("facecam: showing \(device.localizedName)")
        }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        preview.session = nil
        isHidden = true
        // stopRunning blocks, so the recorder gets the camera once this returns
        session.stopRunning()
    }
}
