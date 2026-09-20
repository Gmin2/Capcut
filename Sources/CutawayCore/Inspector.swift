import AppKit

/// Right column: export, the take's name, a list of moments to jump to, and
/// the settings. Every control writes back through the same save path the
/// timeline uses.
public final class InspectorView: ThemedView {
    private let exportButton = FillButton("Export", icon: .download)
    /// Which format Export uses. Nil is the project's own size.
    public var onExportPreset: ((String?) -> Void)?

    @objc private func pickExportPreset(_ item: NSMenuItem) {
        onExportPreset?(item.representedObject as? String)
    }

    /// Greyed out while a render runs, so it cannot be started twice.
    public func setExporting(_ busy: Bool) {
        exportButton.isEnabled = !busy
        exportButton.title = busy ? "Exporting…" : "Export"
    }


    public var apply: ((@escaping (inout Project) -> Void) -> Void)?
    public var onSeek: ((Double) -> Void)?
    public var onExport: (() -> Void)?

    private let content = FlippedStack()
    private var rows: [MomentRow] = []
    private var rowsStart = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)

        let gear = IconButton(.gear, transparent: true)
        gear.onClick = { [weak gear, weak self] in
            guard let gear, let self else { return }
            self.showAppearanceMenu(from: gear)
        }
        let export = exportButton
        export.trailingChevron = true
        export.onClick = { [weak self] in self?.onExport?() }
        export.onChevron = { [weak self, weak export] in
            guard let self, let export else { return }
            let menu = NSMenu()
            for name in ExportPreset.allNames {
                let item = NSMenuItem(title: ExportPreset.named[name]?.name ?? name,
                                      action: #selector(self.pickExportPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: export.bounds.height + 4), in: export)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 16, right: 12)

        let rule = Divider()
        for v in [gear, export, rule, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        content.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            gear.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            gear.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            export.centerYAnchor.constraint(equalTo: gear.centerYAnchor),
            export.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rule.topAnchor.constraint(equalTo: gear.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    public func show(_ p: Project, recording: URL, duration: Double) {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = []

        let date = (try? recording.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy"
        add(Chip(String(format: "%d:%02d", Int(duration) / 60, Int(duration.rounded()) % 60)), gap: 6)
        let title = Theme.label(recording.lastPathComponent, .title, color: Theme.textPrimary)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        add(title, gap: 4)
        add(Theme.label(f.string(from: date), .meta, color: Theme.textSecondary), gap: 14)

        add(SectionHeader("Moments", icon: .bookmark), gap: 6)
        let moments = Self.moments(in: p)
        if moments.isEmpty {
            add(Theme.label("Clicks and scene changes show up here.", .body, color: Theme.textTertiary), gap: 8)
        }
        for (i, m) in moments.enumerated() {
            let row = MomentRow(number: i + 1, time: m.t, title: m.title)
            row.onClick = { [weak self] in self?.onSeek?(m.t) }
            rows.append(row)
            add(row, gap: 6, height: 32)
        }

        section("Look")
        add(pickerRow("Background", ["midnight", "slate", "ember", "forest", "paper", "ink", "screen"],
                      p.backgroundPreset ?? "midnight") { name in
            { $0.backgroundPreset = name; $0.style.background = Style.presets[name] ?? $0.style.background }
        }, gap: 2)
        add(pickerRow("Frame", ["none", "macWindow", "browser", "phone"], p.deviceFrame.rawValue) { name in
            { $0.deviceFrame = DeviceFrame(rawValue: name) ?? .none }
        }, gap: 2)
        // speed of the finished video, not of the preview: this one exports
        add(pickerRow("Speed", ["0.75×", "1×", "1.25×", "1.5×", "2×"],
                      p.speed == 1 ? "1×" : "\(p.speed.clean)×") { name in
            let value = Double(name.replacingOccurrences(of: "×", with: "")) ?? 1
            return { $0.speed = value }
        }, gap: 2)

        section("Camera")
        scrub("Cursor size", p.cursor.scale, 0.8...3.0, 0.1) { $0.cursor.scale = $1 }
        scrub("Smoothing", p.cursor.smoothing, 0...0.9, 0.05) { $0.cursor.smoothing = $1 }
        scrub("Motion blur", p.motionBlur, 0...2, 0.05) { $0.motionBlur = $1 }

        section("Captions")
        toggle("Show captions", p.captions.enabled) { $0.captions.enabled = $1 }
        scrub("Words per line", Double(p.captions.wordsPerCue), 2...8, 1) { $0.captions.wordsPerCue = Int($1) }
        toggle("Show keystrokes", p.keycast.visible) { $0.keycast.visible = $1 }

        section("Audio")
        slider("Voice", p.audio.mic) { $0.audio.mic = $1 }
        slider("System", p.audio.system) { $0.audio.system = $1 }
        toggle("Duck under voice", p.audio.duckSystemUnderVoice) { $0.audio.duckSystemUnderVoice = $1 }
    }

    /// Highlights the moment the playhead is inside.
    public func update(time: Double) {
        let current = rows.lastIndex { $0.time <= time + 0.01 }
        for (i, row) in rows.enumerated() { row.selected = i == current }
    }

    static func moments(in p: Project) -> [(t: Double, title: String)] {
        var out: [(Double, String)] = []
        for (i, sc) in p.scenes.sorted(by: { $0.at < $1.at }).enumerated() where i > 0 {
            out.append((sc.at, "Switch to " + Self.readable(sc.layout)))
        }
        for z in p.zooms { out.append((z.start, String(format: "Zoom in %.1f×", z.level))) }
        for c in p.callouts { out.append((c.at, c.text)) }
        return out.sorted { $0.0 < $1.0 }
    }

    static func readable(_ layout: String) -> String {
        switch layout {
        case "talkingHead": return "talking head"
        case "screenOnly": return "screen"
        case "sideBySide": return "side by side"
        default: return layout
        }
    }

    // MARK: building blocks

    private func add(_ v: NSView, gap: CGFloat, height: CGFloat? = nil) {
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(v)
        content.setCustomSpacing(gap, after: v)
        if !(v is Chip) {
            v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        }
        if let height { v.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    private func section(_ title: String) {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(spacer)
        spacer.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let d = Divider()
        add(d, gap: 12, height: 1)
        add(Theme.label(title.uppercased(), .caption, color: Theme.textTertiary), gap: 6)
    }

    private func scrub(_ name: String, _ value: Double, _ range: ClosedRange<Double>, _ step: Double,
                       _ set: @escaping (inout Project, Double) -> Void) {
        let f = ScrubField(name, value: value, range: range, step: step)
        f.onChange = { [weak self] v in self?.apply? { set(&$0, v) } }
        add(f, gap: 4, height: 30)
    }

    private func slider(_ name: String, _ value: Double, _ set: @escaping (inout Project, Double) -> Void) {
        let s = SliderPill(name, value: value, range: 0...2) { "\(Int(($0 * 100).rounded()))%" }
        s.onChange = { [weak self] v in self?.apply? { set(&$0, v) } }
        add(s, gap: 6, height: 30)
    }

    private func toggle(_ name: String, _ on: Bool, _ set: @escaping (inout Project, Bool) -> Void) {
        let row = NSView()
        let label = Theme.label(name, .body, color: Theme.textSecondary)
        let sw = Switch(on)
        sw.onChange = { [weak self] v in self?.apply? { set(&$0, v) } }
        for v in [label, sw] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sw.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            sw.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sw.widthAnchor.constraint(equalToConstant: 30),
            sw.heightAnchor.constraint(equalToConstant: 18),
        ])
        add(row, gap: 4, height: 30)
    }

    private func pickerRow(_ name: String, _ options: [String], _ selected: String,
                           _ change: @escaping (String) -> (inout Project) -> Void) -> NSView {
        let row = NSView()
        let label = Theme.label(name, .body, color: Theme.textSecondary)
        let dd = Dropdown(options, selected: selected)
        dd.onChange = { [weak self] v in
            let body = change(v)
            self?.apply? { body(&$0) }
        }
        for v in [label, dd] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dd.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            dd.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dd.heightAnchor.constraint(equalToConstant: 28),
            row.heightAnchor.constraint(equalToConstant: 34),
        ])
        return row
    }

    private func showAppearanceMenu(from view: NSView) {
        let menu = NSMenu()
        for (title, mode) in [("Light", "light"), ("Dark", "dark"), ("Match system", "system")] {
            let item = NSMenuItem(title: title, action: #selector(pickAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = Theme.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc private func pickAppearance(_ item: NSMenuItem) {
        guard let mode = item.representedObject as? String else { return }
        Theme.mode = mode
    }
}

/// Numbered row: badge, time, title. Accent outline when the playhead is in it.
final class MomentRow: Control {
    let number: Int
    let time: Double
    let title: String
    var selected = false { didSet { needsDisplay = true } }

    init(number: Int, time: Double, title: String) {
        self.number = number
        self.time = time
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusCard, yRadius: Theme.radiusCard)
        (hovering && !selected ? Theme.fill : Theme.inset).setFill()
        path.fill()
        if selected {
            path.lineWidth = Theme.borderSelected
            Theme.accentBorder.setStroke()
            path.stroke()
        }

        let badge = NSRect(x: 7, y: bounds.midY - 10, width: 20, height: 20)
        (selected ? Theme.accent : Theme.badge).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        let n = "\(number)" as NSString
        let nattrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Text.caption.font,
            .foregroundColor: selected ? Theme.onAccent : Theme.textSecondary,
        ]
        let ns = n.size(withAttributes: nattrs)
        n.draw(at: NSPoint(x: badge.midX - ns.width / 2, y: badge.midY - ns.height / 2), withAttributes: nattrs)

        let stamp = String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60) as NSString
        let sattrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: Theme.textStrong,
        ]
        let ss = stamp.size(withAttributes: sattrs)
        stamp.draw(at: NSPoint(x: 35, y: bounds.midY - ss.height / 2), withAttributes: sattrs)

        let tattrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.body.font,
                                                     .foregroundColor: Theme.textPrimary]
        let tx = 35 + ss.width + 8
        (title as NSString).draw(with: NSRect(x: tx, y: bounds.midY - 8, width: bounds.width - tx - 8, height: 18),
                                 options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                 attributes: tattrs)
    }
}
