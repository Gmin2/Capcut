import AppKit

/// Every capture taken, newest first. Open one to mark it up, copy it, pin it,
/// or throw it away.
@MainActor
public final class CaptureHistory: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private static var shared: CaptureHistory?

    private let window: NSWindow
    private let grid = FlippedStack()
    private let countLabel = Theme.label("", .meta, color: Theme.textSecondary)
    private var cards: [ShotCard] = []
    private var selected: URL?

    public static func show() {
        if let shared {
            shared.reload()
            shared.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        shared = CaptureHistory()
    }

    static var shotCount: Int { shared?.cards.count ?? 0 }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Captures"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 520, height: 420)
        window.delegate = self
        window.center()
        window.contentView = buildLayout()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reload()
    }

    private func buildLayout() -> NSView {
        let root = Surface(Theme.canvas, radius: 0)
        let title = Theme.label("Captures", .title)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = grid

        let folder = FillButton("Show in Finder", icon: .folder) {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.shotsRoot])
        }

        for v in [title, countLabel, scroll, folder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // clear of the traffic lights, which sit over the content
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            countLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            folder.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            folder.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            folder.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            grid.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return root
    }

    func reload() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = []
        let shots = CaptureHistory.allShots()
        countLabel.stringValue = shots.isEmpty
            ? "nothing captured yet, press ⌘⇧6"
            : "\(shots.count) capture\(shots.count == 1 ? "" : "s")"

        var row = rowStack()
        for (i, url) in shots.enumerated() {
            if i > 0, i % 3 == 0 {
                grid.addArrangedSubview(row)
                row = rowStack()
            }
            let card = ShotCard(url: url)
            card.onOpen = { AnnotateWindow.show(url: url) }
            card.onPin = { Pin.show(url: url) }
            card.onCopy = { [weak self] in self?.copy(url) }
            card.onDelete = { [weak self] in self?.trash(url) }
            cards.append(card)
            row.addArrangedSubview(card)
        }
        if !row.arrangedSubviews.isEmpty { grid.addArrangedSubview(row) }
    }

    private func rowStack() -> NSStackView {
        let row = NSStackView()
        row.spacing = 12
        row.alignment = .top
        return row
    }

    /// Newest first, PNGs only. Pure file work, so callable from anywhere.
    nonisolated static func allShots() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Paths.shotsRoot, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "png" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }

    private func copy(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL, image])
    }

    private func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            Log.line("binned \(url.lastPathComponent)")
        } catch {
            Log.line("ERROR: could not bin \(url.lastPathComponent), \(error.localizedDescription)")
        }
        reload()
    }

    public func windowWillClose(_ notification: Notification) {
        CaptureHistory.shared = nil
    }
}

/// One capture in the history: a thumbnail, its name, and what you can do.
final class ShotCard: Control {
    let url: URL
    var onOpen: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?

    private let thumbnail: NSImage?
    private let name: String
    private let when: String

    init(url: URL) {
        self.url = url
        thumbnail = NSImage(contentsOf: url)
        name = url.deletingPathExtension().lastPathComponent
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        when = f.string(from: date)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 216).isActive = true
        heightAnchor.constraint(equalToConstant: 180).isActive = true
        onClick = { [weak self] in self?.onOpen?() }
        toolTip = "Click to mark up. Right-click for more."
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                xRadius: Theme.radiusCard, yRadius: Theme.radiusCard)
        (hovering ? Theme.fillHover : Theme.inset).setFill()
        card.fill()

        let shot = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 124)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: shot, xRadius: 5, yRadius: 5).addClip()
        Theme.badge.setFill()
        shot.fill()
        if let thumbnail {
            let s = min(shot.width / thumbnail.size.width, shot.height / thumbnail.size.height)
            let w = thumbnail.size.width * s, h = thumbnail.size.height * s
            thumbnail.draw(in: NSRect(x: shot.midX - w / 2, y: shot.midY - h / 2, width: w, height: h),
                           from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        (name as NSString).draw(with: NSRect(x: 10, y: 138, width: bounds.width - 20, height: 18),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: Theme.Text.body.font,
                                             .foregroundColor: Theme.textPrimary,
                                             .paragraphStyle: style])
        (when as NSString).draw(at: NSPoint(x: 10, y: 158),
                                withAttributes: [.font: Theme.Text.meta.font,
                                                 .foregroundColor: Theme.textTertiary])
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (title, action) in [("Mark Up", #selector(open)), ("Pin", #selector(pin)),
                                ("Copy", #selector(copyIt)), ("Move to Bin", #selector(remove))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func open() { onOpen?() }
    @objc private func pin() { onPin?() }
    @objc private func copyIt() { onCopy?() }
    @objc private func remove() { onDelete?() }
}
