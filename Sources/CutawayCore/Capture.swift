import AppKit
import ScreenCaptureKit

/// Still captures: drag out an area, or take a whole display.
///
/// The selection runs in its own borderless window over every screen, and the
/// shot is taken after that window is gone, so the dimming and the marching
/// rectangle are never in the picture.
public enum Capture {

    public static func area() {
        Task { @MainActor in
            guard let picked = await SelectionOverlay.pick() else { return }
            await shoot(display: picked.display, region: picked.rect)
        }
    }

    public static func fullScreen(_ displayID: CGDirectDisplayID? = nil) {
        Task { @MainActor in
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
@MainActor
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<(rect: CGRect, display: CGDirectDisplayID)?, Never>?
    private static var live: SelectionOverlay?

    static func pick() async -> (rect: CGRect, display: CGDirectDisplayID)? {
        let overlay = SelectionOverlay()
        live = overlay
        defer { live = nil }
        return await overlay.run()
    }

    private func run() async -> (rect: CGRect, display: CGDirectDisplayID)? {
        await withCheckedContinuation { c in
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
        continuation?.resume(returning: (local, id))
        continuation = nil
    }
}

private final class SelectionView: NSView {
    private weak var overlay: SelectionOverlay?
    private let screen: NSScreen
    private var start: NSPoint?
    private var current: NSPoint?

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

        guard let r = selection, r.width > 0, r.height > 0 else {
            let hint = "Drag to capture an area. Esc to cancel." as NSString
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

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let r = selection else { return }
        let global = NSRect(x: r.minX + screen.frame.minX, y: r.minY + screen.frame.minY,
                            width: r.width, height: r.height)
        overlay?.finish(global, on: screen)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlay?.finish(nil, on: nil) }   // esc
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
        let copy = FillButton("Copy") { [weak self] in self?.copyAgain() }
        let reveal = FillButton("Finder") { [weak self] in self?.reveal() }
        let close = IconButton(.trash) { [weak self] in self?.discard() }
        let row = NSStackView(views: [markup, copy, reveal, close])
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
