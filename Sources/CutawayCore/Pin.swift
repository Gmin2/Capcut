import AppKit

/// A capture stuck on top of everything, to work against while you type
/// somewhere else. Drag it about, scroll to resize, close when done.
@MainActor
public final class Pin: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private static var open: [Pin] = []

    private let window: NSPanel
    private let image: CGImage
    private let url: URL?
    private var zoom: CGFloat = 1

    public static func show(url: URL) {
        guard let image = NSImage(contentsOf: url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Log.line("ERROR: could not open \(url.lastPathComponent) to pin")
            return
        }
        show(image: image, url: url)
    }

    public static func show(image: CGImage, url: URL?) {
        let pin = Pin(image: image, url: url)
        open.append(pin)
    }

    public static func closeAll() {
        for p in open { p.window.orderOut(nil) }
        open.removeAll()
    }

    static var count: Int { open.count }

    private init(image: CGImage, url: URL?) {
        self.image = image
        self.url = url
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // starts at half a Retina capture, which is its natural size on screen
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fitted = Pin.fit(size)
        zoom = fitted.width / size.width

        window = NSPanel(contentRect: NSRect(origin: .zero, size: fitted),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()

        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = PinView(image: image, pin: self)
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - fitted.width / 2,
                                          y: screen.visibleFrame.midY - fitted.height / 2))
        }
        window.orderFrontRegardless()
        Log.line("pinned \(url?.lastPathComponent ?? "capture") at \(Int(fitted.width))x\(Int(fitted.height))")
    }

    private static func fit(_ size: NSSize) -> NSSize {
        let room = NSScreen.main?.visibleFrame.insetBy(dx: 60, dy: 60).size
            ?? NSSize(width: 1200, height: 800)
        let s = min(room.width / size.width, room.height / size.height, 1)
        return NSSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    }

    func resize(by delta: CGFloat) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        zoom = min(max(zoom + delta, 0.15), 3)
        let size = NSSize(width: (natural.width * zoom).rounded(),
                          height: (natural.height * zoom).rounded())
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
    }

    func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    func close() {
        window.orderOut(nil)
        Pin.open.removeAll { $0 === self }
    }

    func markup() {
        if let url { AnnotateWindow.show(url: url) } else { AnnotateWindow.show(image: image, url: nil) }
        close()
    }
}

private final class PinView: NSView {
    private let image: CGImage
    private weak var pin: Pin?
    private var hovering = false { didSet { needsDisplay = true } }

    init(image: CGImage, pin: Pin) {
        self.image = image
        self.pin = pin
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirty: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.6).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        edge.lineWidth = 1
        edge.stroke()

        guard hovering else { return }
        let hint = "scroll to resize · ⌘C copy · esc close" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attrs)
        let pill = NSRect(x: bounds.midX - size.width / 2 - 8, y: 8,
                          width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        hint.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4), withAttributes: attrs)
    }

    override func scrollWheel(with event: NSEvent) {
        pin?.resize(by: event.scrollingDeltaY * 0.004)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers ?? "" {
        case "\u{1b}", "w": pin?.close()
        case "c" where event.modifierFlags.contains(.command): pin?.copyImage()
        case "e": pin?.markup()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { pin?.markup() }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copyIt)), ("Markup", #selector(markupIt)),
                                ("Close", #selector(closeIt))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyIt() { pin?.copyImage() }
    @objc private func markupIt() { pin?.markup() }
    @objc private func closeIt() { pin?.close() }
}
