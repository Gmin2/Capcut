import AppKit

/// The markup editor: the capture on a dotted canvas, one floating toolbar at
/// the bottom, and popovers above it. Laid out after the reference in
/// tmp/claude/annotate: a pill of tools, dividers grouping them, a colour
/// swatch that opens a grid.
public final class AnnotateWindow: NSObject, NSWindowDelegate {

    /// Open editors, kept alive while their window is up.
    nonisolated(unsafe) private static var open: [AnnotateWindow] = []

    private let window: NSWindow
    private let canvas = AnnotateCanvas()
    private let toolbar = Surface(Theme.panel, radius: 26)
    private var url: URL?
    private var toolButtons: [Tool: ToolButton] = [:]
    private let colorButton = SwatchButton()
    private let widthButton = FillButton("Medium")
    private var popover: PopoverView?
    private var editor: NSTextField?
    private var past: [[Mark]] = []
    private var future: [[Mark]] = []

    @discardableResult
    public static func show(url: URL) -> AnnotateWindow? {
        guard let image = NSImage(contentsOf: url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Log.line("ERROR: could not open \(url.lastPathComponent) to annotate")
            return nil
        }
        return show(image: image, url: url)
    }

    @discardableResult
    public static func show(image: CGImage, url: URL?) -> AnnotateWindow {
        let w = AnnotateWindow(image: image, url: url)
        open.append(w)
        return w
    }

    private init(image: CGImage, url: URL?) {
        self.url = url
        let fit = AnnotateWindow.windowSize(for: image)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: fit),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()

        canvas.image = image
        canvas.color = Theme.markColors.first ?? .systemRed
        colorButton.color = canvas.color

        window.title = url?.lastPathComponent ?? "Capture"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 620, height: 460)
        window.delegate = self
        window.center()
        window.contentView = buildLayout()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)

        canvas.onCommit = { [weak self] mark in
            guard let self else { return }
            self.record()
            self.canvas.marks.append(mark)
            self.canvas.selected = self.canvas.marks.count - 1
        }
        canvas.onChange = { [weak self] marks, _ in
            self?.canvas.marks = marks
        }
        canvas.onBeginEdit = { [weak self] i in self?.editText(i) }
        canvas.onKey = { [weak self] event in self?.handle(event) ?? false }
    }

    private static func windowSize(for image: CGImage) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let w = CGFloat(image.width) / scale + 120
        let h = CGFloat(image.height) / scale + 200
        return NSSize(width: min(max(w, 720), screen.width - 40),
                      height: min(max(h, 520), screen.height - 40))
    }

    // MARK: layout

    private func buildLayout() -> NSView {
        let root = Surface(Theme.canvas, radius: 0)

        let tools = NSStackView()
        tools.spacing = 2
        tools.setHuggingPriority(.required, for: .horizontal)
        for tool in Tool.allCases {
            let b = ToolButton(tool)
            b.toolTip = tool.title
            b.onClick = { [weak self] in self?.pick(tool) }
            toolButtons[tool] = b
            tools.addArrangedSubview(b)
        }
        toolButtons[.select]?.selected = true

        colorButton.toolTip = "Colour"
        colorButton.onClick = { [weak self, weak colorButton] in
            guard let self, let colorButton else { return }
            self.toggleColorPopover(from: colorButton)
        }
        widthButton.toolTip = "Thickness"
        widthButton.onClick = { [weak self, weak widthButton] in
            guard let self, let widthButton else { return }
            self.toggleWidthMenu(from: widthButton)
        }

        let cropButton = IconButton(.expand, transparent: false)
        cropButton.toolTip = "Crop"
        cropButton.onClick = { [weak self] in self?.toggleCrop() }

        let frameButton = IconButton(.image, transparent: false)
        frameButton.toolTip = "Background and padding"
        frameButton.onClick = { [weak self, weak frameButton] in
            guard let self, let frameButton else { return }
            self.toggleFramePopover(from: frameButton)
        }

        let undo = IconButton(.undo, transparent: true) { [weak self] in self?.undo() }
        undo.toolTip = "Undo"
        let copy = FillButton("Copy") { [weak self] in self?.copyToClipboard() }
        let save = FillButton("Save", icon: .download) { [weak self] in self?.saveToDisk() }

        let row = NSStackView(views: [tools, Divider.vertical(), colorButton, widthButton,
                                      cropButton, frameButton, Divider.vertical(),
                                      undo, copy, save])
        row.spacing = 10
        row.alignment = .centerY
        // the pill is as wide as its buttons, never the window
        row.distribution = .fill
        row.setHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(row)

        for v in [canvas, toolbar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            row.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            toolbar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
            undo.widthAnchor.constraint(equalToConstant: 30),
            undo.heightAnchor.constraint(equalToConstant: 30),
            copy.heightAnchor.constraint(equalToConstant: 30),
            save.heightAnchor.constraint(equalToConstant: 30),
            colorButton.widthAnchor.constraint(equalToConstant: 30),
            colorButton.heightAnchor.constraint(equalToConstant: 30),
            widthButton.heightAnchor.constraint(equalToConstant: 30),
            cropButton.widthAnchor.constraint(equalToConstant: 30),
            cropButton.heightAnchor.constraint(equalToConstant: 30),
            frameButton.widthAnchor.constraint(equalToConstant: 30),
            frameButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        return root
    }

    // MARK: tools

    private func pick(_ tool: Tool) {
        canvas.tool = tool
        for (t, b) in toolButtons { b.selected = t == tool }
        if tool != .select { canvas.selected = nil }
        closePopover()
    }

    private func toggleColorPopover(from anchor: NSView) {
        if popover != nil { closePopover(); return }
        let content = SwatchGrid(colors: Theme.markColors, selected: canvas.color) { [weak self] c in
            guard let self else { return }
            self.canvas.color = c
            self.colorButton.color = c
            if let i = self.canvas.selected {
                self.record()
                self.canvas.marks[i].color = c
            }
            self.closePopover()
        }
        showPopover(content, from: anchor)
    }

    private func toggleCrop() {
        canvas.isCropping.toggle()
        if canvas.isCropping { pick(.select) }
        closePopover()
    }

    private func applyCrop() {
        record()
        if !canvas.applyCrop() { past.removeLast() }
    }

    private func toggleFramePopover(from anchor: NSView) {
        if popover != nil { closePopover(); return }
        let panel = FramePanel(frame: canvas.dressing, imageWidth: CGFloat(canvas.image?.width ?? 1000))
        panel.onChange = { [weak self] dressing in self?.canvas.dressing = dressing }
        showPopover(panel, from: anchor)
    }

    private func toggleWidthMenu(from anchor: NSView) {
        let menu = NSMenu()
        for (name, value) in [("Thin", CGFloat(2)), ("Medium", 4), ("Thick", 8), ("Heavy", 14)] {
            let item = NSMenuItem(title: name, action: #selector(pickWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(value)
            item.state = abs(canvas.width - value) < 0.1 ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
    }

    @objc private func pickWidth(_ item: NSMenuItem) {
        canvas.width = CGFloat(item.tag)
        widthButton.title = item.title
        if let i = canvas.selected {
            record()
            canvas.marks[i].width = CGFloat(item.tag)
        }
    }

    private func showPopover(_ content: NSView, from anchor: NSView) {
        closePopover()
        guard let root = window.contentView else { return }
        let p = PopoverView(content: content)
        p.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(p)
        let anchorCentre = anchor.convert(NSPoint(x: anchor.bounds.midX, y: 0), to: root)
        NSLayoutConstraint.activate([
            p.centerXAnchor.constraint(equalTo: root.leadingAnchor, constant: anchorCentre.x),
            p.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: 2),
        ])
        popover = p
    }

    private func closePopover() {
        popover?.removeFromSuperview()
        popover = nil
    }

    // MARK: text

    private func editText(_ index: Int) {
        guard canvas.marks.indices.contains(index) else { return }
        let mark = canvas.marks[index]
        let r = canvas.imageRect
        let scale = r.width / canvas.imageSize.width
        let origin = NSPoint(x: r.minX + mark.from.x * scale,
                             y: r.maxY - mark.from.y * scale - 30)

        let field = NSTextField(frame: NSRect(origin: origin, size: NSSize(width: 240, height: 26)))
        field.stringValue = mark.text
        field.font = .systemFont(ofSize: 14)
        field.target = self
        field.action = #selector(commitText(_:))
        field.tag = index
        canvas.addSubview(field)
        window.makeFirstResponder(field)
        editor = field
    }

    @objc private func commitText(_ field: NSTextField) {
        let i = field.tag
        if canvas.marks.indices.contains(i) {
            record()
            canvas.marks[i].text = field.stringValue
        }
        field.removeFromSuperview()
        editor = nil
        window.makeFirstResponder(canvas)
    }

    // MARK: history

    private func record() {
        past.append(canvas.marks)
        future.removeAll()
        if past.count > 50 { past.removeFirst() }
    }

    private func undo() {
        guard let previous = past.popLast() else { return }
        future.append(canvas.marks)
        canvas.marks = previous
        canvas.selected = nil
    }

    private func redo() {
        guard let next = future.popLast() else { return }
        past.append(canvas.marks)
        canvas.marks = next
        canvas.selected = nil
    }

    private func deleteSelected() {
        guard let i = canvas.selected, canvas.marks.indices.contains(i) else { return }
        record()
        canvas.marks.remove(at: i)
        canvas.selected = nil
    }

    // MARK: output

    /// The picture with the marks burned in, at full resolution.
    public func flatten() -> CGImage? {
        guard let image = canvas.image else { return nil }
        let pad = canvas.dressing.padding
        let w = image.width + Int(pad * 2), h = image.height + Int(pad * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: w, height: h)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let picture = NSRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height))
        FrameRenderer.draw(image: image, frame: canvas.dressing,
                           in: NSRect(x: 0, y: 0, width: w, height: h),
                           imageRect: picture, scale: 1)
        MarkRenderer.draw(canvas.marks, selected: nil, pixelated: canvas.pixelatedImage(),
                          imageSize: canvas.imageSize, in: picture)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    public func copyToClipboard() {
        guard let flat = flatten() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: flat, size: NSSize(width: flat.width, height: flat.height))])
        Log.line("copied the marked up capture")
    }

    public func saveToDisk() {
        guard let flat = flatten() else { return }
        let target = url ?? Paths.newShot()
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Still.write(flat, to: target)
            Log.line("saved \(target.lastPathComponent) with \(canvas.marks.count) mark(s)")
        } catch {
            Log.line("ERROR: could not save, \(error.localizedDescription)")
        }
    }

    // MARK: keys

    /// The canvas has first responder, so keys arrive here from it.
    func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.charactersIgnoringModifiers ?? "" {
        case "z" where command && event.modifierFlags.contains(.shift): redo(); return true
        case "z" where command: undo(); return true
        case "c" where command: copyToClipboard(); return true
        case "s" where command: saveToDisk(); return true
        case "\u{7f}", "\u{8}": deleteSelected(); return true
        case "\r": if canvas.isCropping { applyCrop(); return true }; return false
        case "\u{1b}":
            canvas.isCropping = false
            canvas.selected = nil
            closePopover()
            return true
        default: break
        }
        // 1...8 pick a tool, the way every editor does it
        if !command, let n = Int(event.charactersIgnoringModifiers ?? ""),
           n >= 1, n <= Tool.allCases.count {
            pick(Tool.allCases[n - 1])
            return true
        }
        return false
    }

    // MARK: check

    /// Drives the editor with real mouse events and reports what landed, since
    /// a screenshot cannot tell you whether a drag drew anything.
    public func selfCheck(writingTo out: URL) {
        func view(_ image: CGPoint) -> NSPoint {
            let r = canvas.imageRect
            let s = r.width / canvas.imageSize.width
            return NSPoint(x: r.minX + image.x * s, y: r.maxY - image.y * s)
        }
        func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(view(p), to: nil),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func drag(_ a: CGPoint, _ b: CGPoint) {
            canvas.mouseDown(with: event(.leftMouseDown, a))
            canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
            canvas.mouseDragged(with: event(.leftMouseDragged, b))
            canvas.mouseUp(with: event(.leftMouseUp, b))
        }
        func click(_ p: CGPoint, clicks: Int = 1) {
            canvas.mouseDown(with: event(.leftMouseDown, p, clicks: clicks))
            canvas.mouseUp(with: event(.leftMouseUp, p, clicks: clicks))
        }
        func report(_ name: String, _ ok: Bool, _ detail: String) {
            Log.line("annotate: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        }

        pick(.box)
        drag(CGPoint(x: 100, y: 100), CGPoint(x: 460, y: 320))
        report("box drawn", canvas.marks.count == 1 && canvas.marks.last?.tool == .box,
               "marks \(canvas.marks.count)")

        pick(.arrow)
        drag(CGPoint(x: 560, y: 150), CGPoint(x: 880, y: 400))
        report("arrow drawn", canvas.marks.count == 2 && canvas.marks.last?.tool == .arrow,
               "marks \(canvas.marks.count)")

        pick(.highlight)
        drag(CGPoint(x: 100, y: 520), CGPoint(x: 620, y: 600))
        report("highlight drawn", canvas.marks.count == 3, "marks \(canvas.marks.count)")

        pick(.blur)
        drag(CGPoint(x: 680, y: 500), CGPoint(x: 980, y: 660))
        report("blur drawn", canvas.marks.count == 4, "marks \(canvas.marks.count)")

        pick(.step)
        click(CGPoint(x: 1060, y: 180))
        click(CGPoint(x: 1060, y: 320))
        report("steps numbered", canvas.marks.suffix(2).map(\.number) == [1, 2],
               "numbers \(canvas.marks.suffix(2).map(\.number))")

        pick(.text)
        click(CGPoint(x: 160, y: 760))
        if let i = canvas.marks.indices.last {
            canvas.marks[i].text = "Look here"
            editor?.removeFromSuperview()
            editor = nil
        }
        report("text placed", canvas.marks.last?.tool == .text, "marks \(canvas.marks.count)")

        let beforeUndo = canvas.marks.count
        undo()
        let afterUndo = canvas.marks.count
        redo()
        report("undo and redo", afterUndo == beforeUndo - 1 && canvas.marks.count == beforeUndo,
               "\(beforeUndo) -> \(afterUndo) -> \(canvas.marks.count)")

        // a stray click with a drag tool must not leave an invisible mark
        pick(.box)
        click(CGPoint(x: 300, y: 300))
        report("stray click ignored", canvas.marks.count == beforeUndo, "marks \(canvas.marks.count)")

        pick(.select)
        click(CGPoint(x: 100, y: 100))
        let picked = canvas.selected
        let startX = picked.map { canvas.marks[$0].from.x } ?? -1
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 140, y: 100)))
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 140, y: 100)))
        let movedX = picked.map { canvas.marks[$0].from.x } ?? -1
        report("select and move", picked != nil && movedX - startX > 30,
               String(format: "x %.0f -> %.0f", startX, movedX))

        // crop: keep the middle, and every mark must move with it
        let beforeCrop = canvas.imageSize
        let markBefore = canvas.marks[0].from
        canvas.isCropping = true
        drag(CGPoint(x: 80, y: 60), CGPoint(x: 1080, y: 700))
        applyCrop()
        // a drag is limited by the on-screen scale, so allow a pixel either way
        report("crop applied", abs(canvas.imageSize.width - 1000) <= 2
               && abs(canvas.imageSize.height - 640) <= 2,
               "\(Int(beforeCrop.width))x\(Int(beforeCrop.height)) -> "
               + "\(Int(canvas.imageSize.width))x\(Int(canvas.imageSize.height))")
        report("marks moved with the crop",
               abs(canvas.marks[0].from.x - (markBefore.x - 80)) <= 2,
               String(format: "x %.0f -> %.0f", markBefore.x, canvas.marks[0].from.x))

        // dressing: a background with padding, corners and a shadow
        canvas.dressing.background = Frame.presets[1]
        canvas.dressing.padding = 80
        canvas.dressing.corner = 18
        canvas.dressing.shadow = 0.5
        let framed = flatten()
        report("frame padding", framed?.width == (canvas.image?.width ?? 0) + 160,
               "width \(framed?.width ?? -1)")
        if let framed, let url = try? URL(fileURLWithPath: out.path)
            .deletingLastPathComponent().appendingPathComponent("annotate-framed.png") {
            try? Still.write(framed, to: url)
        }
        canvas.dressing = Frame()

        guard let flat = flatten() else {
            report("export", false, "nothing rendered")
            return
        }
        do {
            try Still.write(flat, to: out)
            report("export", flat.width == canvas.image?.width,
                   "\(flat.width)x\(flat.height) -> \(out.lastPathComponent)")
        } catch {
            report("export", false, error.localizedDescription)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        AnnotateWindow.open.removeAll { $0 === self }
    }
}

// MARK: - pieces

/// One tool in the pill. Selected shows the chip behind the icon.
final class ToolButton: Control {
    let tool: Tool
    var selected = false { didSet { needsDisplay = true } }

    init(_ tool: Tool) {
        self.tool = tool
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 32) }

    override func draw(_ dirty: NSRect) {
        if selected || hovering {
            (selected ? Theme.fillSelected : Theme.fill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let ink = selected ? Theme.textStrong : Theme.icon
        // box and ellipse read better as the shape itself than as any icon
        switch tool {
        case .box:
            let r = NSRect(x: bounds.midX - 8, y: bounds.midY - 6.5, width: 16, height: 13)
            let p = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
            p.lineWidth = 1.6
            ink.setStroke()
            p.stroke()
        case .ellipse:
            let p = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 8, y: bounds.midY - 6.5,
                                                width: 16, height: 13))
            p.lineWidth = 1.6
            ink.setStroke()
            p.stroke()
        default:
            tool.icon.draw(in: NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16),
                           color: ink)
        }
    }
}

/// The current colour, as a filled circle.
final class SwatchButton: Control {
    var color = NSColor.systemRed { didSet { needsDisplay = true } }

    override func draw(_ dirty: NSRect) {
        if hovering {
            Theme.fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let r = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        Theme.divider.setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// Seven per row, like the reference.
final class SwatchGrid: ThemedView {
    private let colors: [NSColor]
    private let selected: NSColor
    private let onPick: (NSColor) -> Void
    private var frames: [NSRect] = []
    private let columns = 7
    private let cell: CGFloat = 30

    init(colors: [NSColor], selected: NSColor, onPick: @escaping (NSColor) -> Void) {
        self.colors = colors
        self.selected = selected
        self.onPick = onPick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let rows = (colors.count + columns - 1) / columns
        return NSSize(width: CGFloat(columns) * cell, height: CGFloat(rows) * cell)
    }

    override func draw(_ dirty: NSRect) {
        frames = []
        for (i, c) in colors.enumerated() {
            let x = CGFloat(i % columns) * cell
            let y = CGFloat(i / columns) * cell
            let box = NSRect(x: x, y: y, width: cell, height: cell)
            frames.append(box)
            let dot = box.insetBy(dx: 5, dy: 5)
            c.setFill()
            NSBezierPath(ovalIn: dot).fill()
            if c == selected {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 2
                Theme.textStrong.setStroke()
                ring.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = frames.firstIndex(where: { $0.contains(p) }), i < colors.count else { return }
        onPick(colors[i])
    }
}

/// A panel above the toolbar with a little tail pointing down at what opened it.
final class PopoverView: ThemedView {
    private let tail: CGFloat = 9

    init(content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14 - tail),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let body = NSRect(x: 0, y: tail, width: bounds.width, height: bounds.height - tail)
        let path = NSBezierPath(roundedRect: body, xRadius: 16, yRadius: 16)
        let point = NSBezierPath()
        point.move(to: NSPoint(x: bounds.midX - tail, y: tail + 0.5))
        point.line(to: NSPoint(x: bounds.midX, y: 0))
        point.line(to: NSPoint(x: bounds.midX + tail, y: tail + 0.5))
        point.close()

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        Theme.panel.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.panel.setFill()
        point.fill()
    }
}

extension Divider {
    /// The thin rules that group the toolbar.
    static func vertical() -> NSView {
        let v = VerticalRule()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }
}

final class VerticalRule: ThemedView {
    override func draw(_ dirty: NSRect) {
        Theme.divider.setFill()
        bounds.fill()
    }
}

/// Background, padding, corners and shadow, laid out like the reference's
/// Frame panel: a swatch grid, then one row per number.
final class FramePanel: ThemedView {
    var onChange: ((Frame) -> Void)?

    private var model: Frame
    private let imageWidth: CGFloat
    private let grid: BackgroundGrid
    private let padding: SliderPill
    private let corners: SliderPill
    private let shadowSlider: SliderPill

    init(frame model: Frame, imageWidth: CGFloat) {
        self.model = model
        self.imageWidth = imageWidth
        grid = BackgroundGrid(selected: model.background)
        padding = SliderPill("Padding", value: Double(model.padding), range: 0...Double(imageWidth / 3),
                             format: { "\(Int($0))" })
        corners = SliderPill("Corners", value: Double(model.corner), range: 0...80,
                             format: { "\(Int($0))" })
        shadowSlider = SliderPill("Shadow", value: model.shadow, range: 0...1)
        super.init(frame: .zero)

        let title = Theme.label("Frame", .title)
        let stack = NSStackView(views: [title, grid, padding, corners, shadowSlider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            padding.widthAnchor.constraint(equalToConstant: 260),
            corners.widthAnchor.constraint(equalToConstant: 260),
            shadowSlider.widthAnchor.constraint(equalToConstant: 260),
        ])

        grid.onPick = { [weak self] background in
            guard let self else { return }
            self.model.background = background
            // a background with no padding shows nothing, so open it up
            if self.model.padding < 1 {
                self.model.padding = (self.imageWidth / 12).rounded()
                self.padding.value = Double(self.model.padding)
                if self.model.corner < 1 {
                    self.model.corner = 16
                    self.corners.value = 16
                }
            }
            self.onChange?(self.model)
        }
        padding.onChange = { [weak self] v in
            guard let self else { return }
            self.model.padding = CGFloat(v.rounded())
            self.onChange?(self.model)
        }
        corners.onChange = { [weak self] v in
            guard let self else { return }
            self.model.corner = CGFloat(v.rounded())
            self.onChange?(self.model)
        }
        shadowSlider.onChange = { [weak self] v in
            guard let self else { return }
            self.model.shadow = v
            self.onChange?(self.model)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Seven backgrounds per row, gradients drawn as the gradient itself.
final class BackgroundGrid: ThemedView {
    var onPick: ((Frame.Background) -> Void)?
    private var chosen: Frame.Background
    private var frames: [NSRect] = []
    private let columns = 7
    private let cell: CGFloat = 34

    init(selected chosen: Frame.Background) {
        self.chosen = chosen
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let rows = (Frame.presets.count + columns - 1) / columns
        return NSSize(width: CGFloat(columns) * cell, height: CGFloat(rows) * cell)
    }

    override func draw(_ dirty: NSRect) {
        frames = []
        for (i, background) in Frame.presets.enumerated() {
            let box = NSRect(x: CGFloat(i % columns) * cell, y: CGFloat(i / columns) * cell,
                             width: cell, height: cell)
            frames.append(box)
            let dot = box.insetBy(dx: 5, dy: 5)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: dot).addClip()
            background.fill(dot)
            NSGraphicsContext.restoreGraphicsState()
            Theme.divider.setStroke()
            let edge = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = frames.firstIndex(where: { $0.contains(p) }), i < Frame.presets.count else { return }
        chosen = Frame.presets[i]
        needsDisplay = true
        onPick?(Frame.presets[i])
    }
}
