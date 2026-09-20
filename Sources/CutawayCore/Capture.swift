import AppKit
import ScreenCaptureKit

/// Still captures: drag out an area, or take a whole display.
///
/// The selection runs in its own borderless window over every screen, and the
/// shot is taken after that window is gone, so the dimming and the marching
/// rectangle are never in the picture.
public enum Capture {

    /// Seconds to wait before a capture, so a menu can be opened first.
    public static var timer: Int {
        get { UserDefaults.standard.integer(forKey: "capture.timer") }
        set { UserDefaults.standard.set(newValue, forKey: "capture.timer") }
    }

    public static func area() {
        Task { @MainActor in
            guard let picked = await SelectionOverlay.pick() else { return }
            await countdown()
            switch picked {
            case .area(let rect, let display):
                await shoot(display: display, region: rect)
            case .window(let window):
                await shoot(window: window)
            }
        }
    }

    @MainActor
    private static func countdown() async {
        let seconds = timer
        guard seconds > 0 else { return }
        await withCheckedContinuation { c in
            Countdown().run(from: seconds) { c.resume() }
        }
    }

    /// One window on its own, with everything behind it left out.
    @MainActor
    static func shoot(window: SCWindow) async {
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config)
            finish(image)
        } catch {
            Log.line("ERROR: window capture failed, \(error.localizedDescription)")
        }
    }

    public static func fullScreen(_ displayID: CGDirectDisplayID? = nil) {
        Task { @MainActor in
            await countdown()
            let id = displayID ?? NSScreen.main.flatMap {
                $0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID
            } ?? CGMainDisplayID()
            await shoot(display: id, region: nil)
        }
    }

    /// - Parameter region: display points with the origin top left. Nil takes
    ///   the whole display.
    @MainActor
    static func shoot(display id: CGDirectDisplayID, region: CGRect?) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id })
                    ?? content.displays.first else {
                Log.line("ERROR: no display to capture")
                return
            }
            // our own windows are never part of a capture
            let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let scale = NSScreen.screens.first {
                ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }?.backingScaleFactor ?? 2

            let bounds = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
            let area = (region?.integral.intersection(bounds)).flatMap { $0.width >= 8 && $0.height >= 8 ? $0 : nil }
            let config = SCStreamConfiguration()
            config.width = Int((area ?? bounds).width * scale)
            config.height = Int((area ?? bounds).height * scale)
            config.showsCursor = false
            if let area { config.sourceRect = area }

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: mine),
                configuration: config)
            finish(image)
        } catch {
            Log.line("ERROR: capture failed, \(error.localizedDescription)")
        }
    }

    @MainActor
    static func finish(_ image: CGImage) {
        let url = Paths.newShot()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Still.write(image, to: url)
        } catch {
            Log.line("ERROR: could not save the capture, \(error.localizedDescription)")
            return
        }
        copyToClipboard(url: url, image: image)
        Log.line("capture \(image.width)x\(image.height) -> \(url.lastPathComponent)")
        Shelf.shared.show(url: url, image: image)
    }

    /// Captures the same area over and over while you scroll, then joins the
    /// frames into one tall picture. Manual scrolling on purpose: sending
    /// scroll events would need Accessibility, and pages that hijack the wheel
    /// would fight it anyway.
    @MainActor
    public static func scrolling() {
        Task { @MainActor in
            guard case .area(let rect, let display)? = await SelectionOverlay.pick() else { return }
            await ScrollingSession(display: display, region: rect).run()
        }
    }

    /// Desktop icons off makes a capture of the desktop look deliberate.
    /// Finder has to be restarted for it either way, which it survives.
    public static var desktopIconsHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "capture.hideIcons") }
        set {
            UserDefaults.standard.set(newValue, forKey: "capture.hideIcons")
            setFinderDesktop(visible: !newValue)
        }
    }

    private static func setFinderDesktop(visible: Bool) {
        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        write.arguments = ["write", "com.apple.finder", "CreateDesktop", visible ? "true" : "false"]
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Finder"]
        do {
            try write.run()
            write.waitUntilExit()
            try restart.run()
            Log.line("desktop icons \(visible ? "shown" : "hidden"), Finder restarted")
        } catch {
            Log.line("ERROR: could not change the desktop, \(error.localizedDescription)")
        }
    }

    /// Newest shot on disk, for "markup the last one".
    public static func lastShot() -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Paths.shotsRoot, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        return items.filter { $0.pathExtension.lowercased() == "png" }.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
    }

    static func copyToClipboard(url: URL, image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // both, so Finder takes the file and a chat window takes the picture
        pb.writeObjects([url as NSURL,
                         NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }
}

// MARK: - selection

/// The dim-and-drag layer. One window per screen so a selection can start on
/// any of them.
enum Picked {
    case area(CGRect, CGDirectDisplayID)
    case window(SCWindow)
}

@MainActor
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<Picked?, Never>?
    private static var live: SelectionOverlay?
    /// Windows on screen, for the space-bar window mode.
    private var pickable: [(window: SCWindow, frame: NSRect)] = []

    static func pick() async -> Picked? {
        let overlay = SelectionOverlay()
        live = overlay
        defer { live = nil }
        return await overlay.run()
    }

    private func run() async -> Picked? {
        Task { await loadWindows() }
        return await withCheckedContinuation { c in
            continuation = c
            for screen in NSScreen.screens {
                let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
                w.level = .screenSaver
                w.isOpaque = false
                w.backgroundColor = .clear
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                w.contentView = SelectionView(screen: screen, overlay: self)
                w.orderFrontRegardless()
                windows.append(w)
            }
            NSApp.activate(ignoringOtherApps: true)
            windows.first?.makeKey()
        }
    }

    /// SCWindow frames are y-down from the top of the main display; the
    /// overlay works in AppKit points, y-up.
    static func appKitFrame(_ frame: CGRect, mainHeight: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static let notWindows: Set<String> = [
        "com.apple.dock", "com.apple.controlcenter", "com.apple.WindowManager",
        "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.Spotlight",
    ]

    private func loadWindows() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true) else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = getpid()
        let found = content.windows.filter {
            // a real window, not the menu bar, the dock or a floating strip
            $0.windowLayer == 0 && $0.frame.width > 160 && $0.frame.height > 120
                && $0.owningApplication?.processID != me
                && !SelectionOverlay.notWindows.contains($0.owningApplication?.bundleIdentifier ?? "")
        }.map { ($0, SelectionOverlay.appKitFrame($0.frame, mainHeight: mainHeight)) }
        await MainActor.run {
            self.pickable = found
            for w in self.windows { w.contentView?.needsDisplay = true }
        }
    }

    /// Smallest window under the pointer, which is the one a person means.
    func window(at point: NSPoint) -> (window: SCWindow, frame: NSRect)? {
        pickable.filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    func finishWindow(_ window: SCWindow) {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        continuation?.resume(returning: .window(window))
        continuation = nil
    }

    /// AppKit y-up global -> display-local y-down, which is what capture wants.
    /// Split out so the conversion can be checked without a screen.
    static func local(_ rect: NSRect, on screenFrame: NSRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// `rect` is in global AppKit points, y up.
    func finish(_ rect: NSRect?, on screen: NSScreen?) {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        guard let rect, let screen, rect.width >= 4, rect.height >= 4,
              let id = screen.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID else {
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        let local = SelectionOverlay.local(rect, on: screen.frame)
        continuation?.resume(returning: .area(local, id))
        continuation = nil
    }
}

private final class SelectionView: NSView {
    private weak var overlay: SelectionOverlay?
    private let screen: NSScreen
    private var start: NSPoint?
    private var current: NSPoint?
    private var windowMode = false
    private var hovered: (window: SCWindow, frame: NSRect)?

    init(screen: NSScreen, overlay: SelectionOverlay) {
        self.screen = screen
        self.overlay = overlay
        super.init(frame: screen.frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if windowMode {
            drawWindowMode()
            return
        }

        guard let r = selection, r.width > 0, r.height > 0 else {
            let hint = "Drag to capture an area. Space for a window. Esc to cancel." as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY),
                      withAttributes: attrs)
            return
        }

        // punch the selection back out of the dim
        NSColor.clear.setFill()
        r.fill(using: .copy)
        let outline = NSBezierPath(rect: r)
        outline.lineWidth = 1.5
        NSColor(srgbRed: 0, green: 0.71, blue: 1, alpha: 1).setStroke()
        outline.stroke()

        let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        var tag = NSRect(x: r.minX, y: r.maxY + 8, width: size.width + 14, height: size.height + 8)
        if tag.maxY > bounds.maxY { tag.origin.y = r.minY - tag.height - 8 }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: tag, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: tag.minX + 7, y: tag.minY + 4), withAttributes: attrs)
    }

    private func drawWindowMode() {
        let hint = "Click a window. Space for an area. Esc to cancel." as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let size = hint.size(withAttributes: attrs)
        hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY),
                  withAttributes: attrs)

        guard let hovered else { return }
        let local = NSRect(x: hovered.frame.minX - screen.frame.minX,
                           y: hovered.frame.minY - screen.frame.minY,
                           width: hovered.frame.width, height: hovered.frame.height)
        NSColor.clear.setFill()
        local.fill(using: .copy)
        let outline = NSBezierPath(rect: local)
        outline.lineWidth = 2
        NSColor(srgbRed: 0, green: 0.71, blue: 1, alpha: 1).setStroke()
        outline.stroke()
    }

    override func mouseMoved(with event: NSEvent) {
        guard windowMode else { return }
        let global = NSPoint(x: convert(event.locationInWindow, from: nil).x + screen.frame.minX,
                             y: convert(event.locationInWindow, from: nil).y + screen.frame.minY)
        hovered = overlay?.window(at: global)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        if windowMode {
            if let hovered { overlay?.finishWindow(hovered.window) }
            return
        }
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !windowMode else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !windowMode else { return }
        current = convert(event.locationInWindow, from: nil)
        guard let r = selection else { return }
        let global = NSRect(x: r.minX + screen.frame.minX, y: r.minY + screen.frame.minY,
                            width: r.width, height: r.height)
        overlay?.finish(global, on: screen)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: overlay?.finish(nil, on: nil)   // esc
        case 49:                                  // space
            windowMode.toggle()
            start = nil
            current = nil
            hovered = nil
            needsDisplay = true
        default: break
        }
    }
}

// MARK: - what happens after

/// The thumbnail that appears in the corner after a capture: drag it into a
/// chat, copy it again, show it in Finder, or throw it away.
@MainActor
public final class Shelf: NSObject, NSDraggingSource {
    public static let shared = Shelf()

    private var panel: NSPanel?
    private var url: URL?
    private var thumb: ThumbView?
    private var hideTimer: Timer?

    public func show(url: URL, image: CGImage) {
        self.url = url
        if panel == nil { build() }
        thumb?.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        place()
        panel?.orderFrontRegardless()
        restartTimer()
    }

    public func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }

    private func restartTimer() {
        hideTimer?.invalidate()
        // long enough to drag it somewhere, short enough to stay out of the way
        hideTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 232, height: 172),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)

        let root = Surface(NSColor(white: 0.12, alpha: 0.96))
        let thumb = ThumbView(shelf: self)
        self.thumb = thumb

        let markup = FillButton("Markup") { [weak self] in self?.annotate() }
        let pin = FillButton("Pin") { [weak self] in self?.pinIt() }
        pin.toolTip = "Keep this on top of everything"
        let text = FillButton("Text") { [weak self] in self?.copyText() }
        text.toolTip = "Copy the words in this capture"
        let copy = FillButton("Copy") { [weak self] in self?.copyAgain() }
        let reveal = FillButton("Finder") { [weak self] in self?.reveal() }
        let close = IconButton(.trash) { [weak self] in self?.discard() }
        let row = NSStackView(views: [markup, pin, text, copy, reveal, close])
        row.spacing = 8

        for v in [thumb, row] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            thumb.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            thumb.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            thumb.heightAnchor.constraint(equalToConstant: 112),
            row.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: thumb.leadingAnchor),
            row.heightAnchor.constraint(equalToConstant: 28),
            close.widthAnchor.constraint(equalToConstant: 28),
        ])
        p.contentView = root
        panel = p
    }

    private func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.minX + 24, y: area.minY + 24))
    }

    func annotate() {
        guard let url else { return }
        AnnotateWindow.show(url: url)
        hide()
    }

    private func pinIt() {
        guard let url else { return }
        Pin.show(url: url)
        hide()
    }

    private func copyText() {
        guard let url, let image = NSImage(contentsOf: url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Task { @MainActor in
            _ = await TextInImage.copyEverything(from: image)
            self.restartTimer()
        }
    }

    private func copyAgain() {
        guard let url, let image = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL, image])
        restartTimer()
    }

    private func reveal() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        hide()
    }

    private func discard() {
        if let url { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        url = nil
        hide()
    }

    /// Dragging the thumbnail hands over the real file, so it lands in Slack,
    /// Finder or anywhere else that takes a drop.
    func beginDrag(with event: NSEvent, from view: NSView) {
        guard let url, let image = thumb?.image else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(view.bounds, contents: image)
        view.beginDraggingSession(with: [item], event: event, source: self)
        restartTimer()
    }

    public nonisolated func draggingSession(_ session: NSDraggingSession,
                                            sourceOperationMaskFor context: NSDraggingContext)
    -> NSDragOperation { [.copy] }
}

private final class ThumbView: Control {
    var image: NSImage? { didSet { needsDisplay = true } }
    private weak var shelf: Shelf?

    init(shelf: Shelf) {
        self.shelf = shelf
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(white: 0.2, alpha: 1).setFill()
        path.fill()
        guard let image else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let s = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        image.draw(in: NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDragged(with event: NSEvent) {
        shelf?.beginDrag(with: event, from: self)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { shelf?.annotate() }
    }
}

// MARK: - scrolling capture

/// Runs while you scroll: a small panel with a Done button, and a frame of the
/// chosen area four times a second.
@MainActor
final class ScrollingSession {
    private let display: CGDirectDisplayID
    private let region: CGRect
    private var frames: [CGImage] = []
    private var panel: NSPanel?
    private var stopped = false
    private var busy = false

    init(display: CGDirectDisplayID, region: CGRect) {
        self.display = display
        self.region = region
    }

    func run() async {
        showPanel()
        let started = Date()
        while !stopped, Date().timeIntervalSince(started) < 120 {
            await grab()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        panel?.orderOut(nil)
        panel = nil

        guard frames.count > 1, let tall = Stitch.vertical(frames) else {
            Log.line("scrolling capture: nothing to join")
            if let one = frames.first { Capture.finish(one) }
            return
        }
        Log.line("scrolling capture: \(frames.count) frames -> \(tall.width)x\(tall.height)")
        Capture.finish(tall)
    }

    /// Frames are dropped if one is still in flight, so a slow capture cannot
    /// build a backlog of stale pictures.
    private func grab() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true),
              let screen = content.displays.first(where: { $0.displayID == display }) else { return }
        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display
        }?.backingScaleFactor ?? 2

        let config = SCStreamConfiguration()
        config.width = Int(region.width * scale)
        config.height = Int(region.height * scale)
        config.showsCursor = false
        config.sourceRect = region
        if let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: screen, excludingWindows: mine),
            configuration: config) {
            frames.append(image)
        }
    }

    private func showPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 66),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let root = Surface(NSColor(white: 0.1, alpha: 0.92), radius: 14)
        let label = Theme.label("Scroll the page", .body, color: .white)
        let done = FillButton("Done") { [weak self] in self?.stopped = true }
        for v in [label, done] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            done.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            done.heightAnchor.constraint(equalToConstant: 30),
        ])
        p.contentView = root
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 150,
                                     y: screen.visibleFrame.minY + 40))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func stop() { stopped = true }
}
