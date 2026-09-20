import AppKit

// Tokens from DESIGN.md. Every colour resolves against the drawing appearance,
// so a view that draws with these in draw(_:) is correct in both themes for free.
public enum Theme {

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return hex(isDark ? dark : light)
        }
    }

    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    public static let canvas        = dynamic(0xFFFFFF, 0x232323)
    public static let panel         = dynamic(0xF8F8F8, 0x272727)
    public static let inset         = dynamic(0xF2F2F2, 0x2D2D2D)
    public static let fill          = dynamic(0xEDEDED, 0x343434)
    public static let fillHover     = dynamic(0xE5E5E5, 0x3B3B3B)
    public static let fillSelected  = dynamic(0xE4F1F7, 0x414141)
    public static let badge         = dynamic(0xE2E2E2, 0x3E3E3E)
    public static let divider       = dynamic(0xE6E6E6, 0x303030)
    public static let textPrimary   = dynamic(0x333333, 0xEDEDED)
    public static let textStrong    = dynamic(0x1F1F1F, 0xFFFFFF)
    public static let textSecondary = dynamic(0x636363, 0xA0A0A0)
    public static let textTertiary  = dynamic(0x8A8A8A, 0x7B7B7B)
    public static let icon          = dynamic(0x696969, 0x7D7D7D)
    public static let accent        = dynamic(0x00B4FF, 0xFFAA00)
    public static let accentBorder  = dynamic(0x3FB2E6, 0xFFAA00)
    public static let cardOutline   = dynamic(0x3FB2E6, 0xA6A6A6)
    public static let onAccent      = dynamic(0xFFFFFF, 0x1A1A1A)
    public static let record        = hex(0xF2493F)
    public static let waveform      = dynamic(0xDADADA, 0x3B3B3B)
    public static let track         = dynamic(0xE0E0E0, 0x3A3A3A)

    public static let radiusPanel: CGFloat = 12
    public static let radiusCard: CGFloat = 8
    public static let radiusControl: CGFloat = 6
    public static let borderSelected: CGFloat = 1.5
    public static let gutter: CGFloat = 12

    public enum Text {
        case time, title, body, bodyStrong, meta, caption

        var font: NSFont {
            switch self {
            case .time: return .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            case .title: return .systemFont(ofSize: 15, weight: .semibold)
            case .body: return .systemFont(ofSize: 13, weight: .regular)
            case .bodyStrong: return .systemFont(ofSize: 13, weight: .medium)
            case .meta: return .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            case .caption: return .systemFont(ofSize: 11, weight: .medium)
            }
        }
    }

    public static func label(_ s: String, _ style: Text = .body,
                             color: NSColor = textPrimary) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = style.font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    /// The markup palette, in the order the grid shows them: strong colours
    /// first, because a mark is meant to be seen.
    public static let markColors: [NSColor] = [
        NSColor(srgbRed: 0.91, green: 0.24, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.55, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.80, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.25, green: 0.70, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.15, green: 0.60, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.36, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.29, blue: 0.79, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1),
        NSColor(srgbRed: 0.40, green: 0.43, blue: 0.47, alpha: 1),
        NSColor.white,
        NSColor(srgbRed: 0.00, green: 0.66, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.20, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.42, blue: 0.29, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.55, blue: 0.16, alpha: 1),
    ]

    /// Light unless the user picked otherwise. Dark is tuned but light is the
    /// reference we matched first.
    public static var mode: String {
        get { UserDefaults.standard.string(forKey: "appearance") ?? "light" }
        set { UserDefaults.standard.set(newValue, forKey: "appearance"); apply() }
    }

    public static func apply() {
        switch mode {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}

// MARK: - base

/// A view that repaints when the theme changes, so tokens re-resolve.
open class ThemedView: NSView {
    open override var isFlipped: Bool { true }
    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        subviews.forEach { $0.needsDisplay = true }
    }
}

/// A filled, rounded container. Panels, wells and cards are all this.
public final class Surface: ThemedView {
    public var color: NSColor { didSet { needsDisplay = true } }
    public var radius: CGFloat { didSet { needsDisplay = true } }
    public var border: NSColor? { didSet { needsDisplay = true } }

    public init(_ color: NSColor, radius: CGFloat = Theme.radiusPanel, border: NSColor? = nil) {
        self.color = color
        self.radius = radius
        self.border = border
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirty: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        if let border {
            let inset = bounds.insetBy(dx: Theme.borderSelected / 2, dy: Theme.borderSelected / 2)
            let b = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
            b.lineWidth = Theme.borderSelected
            border.setStroke()
            b.stroke()
        }
    }
}

public final class Divider: ThemedView {
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    public override func draw(_ dirty: NSRect) {
        Theme.divider.setFill()
        bounds.fill()
    }
}

/// Hover and press tracking shared by every clickable control.
open class Control: ThemedView {
    public var onClick: (() -> Void)?
    public var isEnabled = true { didSet { needsDisplay = true } }
    var hovering = false
    var pressed = false

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    open override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    open override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    open override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    open override func mouseUp(with event: NSEvent) {
        guard isEnabled, pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    var fillColor: NSColor {
        if !isEnabled { return Theme.fill }
        return hovering || pressed ? Theme.fillHover : Theme.fill
    }

    var inkColor: NSColor { isEnabled ? Theme.textPrimary : Theme.textTertiary }
}

// MARK: - controls

public final class FillButton: Control {
    public var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var icon: Icon? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var showsDot = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var trailingChevron = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var transparent = false { didSet { needsDisplay = true } }
    /// Split buttons: a click on the chevron side goes here instead of onClick.
    public var onChevron: (() -> Void)?

    public init(_ title: String, icon: Icon? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.icon = icon
        super.init(frame: .zero)
        onClick = action
    }

    required init?(coder: NSCoder) { fatalError() }

    private var leading: CGFloat { (icon != nil || showsDot) ? 22 : 0 }
    private var trailing: CGFloat { trailingChevron ? 27 : 0 }

    public override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if trailingChevron, let onChevron, isEnabled, pressed,
           bounds.contains(p), p.x > bounds.maxX - trailing {
            pressed = false
            needsDisplay = true
            onChevron()
            return
        }
        super.mouseUp(with: event)
    }

    public override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: Theme.Text.body.font]).width
        return NSSize(width: ceil(w) + 24 + leading + trailing, height: 28)
    }

    public override func draw(_ dirty: NSRect) {
        if !transparent || hovering {
            fillColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusControl,
                         yRadius: Theme.radiusControl).fill()
        }

        var x: CGFloat = 12
        let midY = bounds.midY
        if showsDot {
            let dot = NSRect(x: x + 2, y: midY - 4, width: 8, height: 8)
            (isEnabled ? Theme.record : Theme.textTertiary).setFill()
            NSBezierPath(ovalIn: dot).fill()
            x += leading
        } else if let icon {
            icon.draw(in: NSRect(x: x, y: midY - 7, width: 14, height: 14),
                      color: isEnabled ? Theme.icon : Theme.textTertiary)
            x += leading
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.body.font,
                                                    .foregroundColor: inkColor]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: x, y: midY - size.height / 2), withAttributes: attrs)

        if trailingChevron {
            let sepX = bounds.maxX - trailing
            Theme.divider.setFill()
            NSRect(x: sepX, y: 7, width: 1, height: bounds.height - 14).fill()
            Icon.chevronDown.draw(in: NSRect(x: sepX + 8, y: midY - 5, width: 10, height: 10),
                                  color: Theme.icon)
        }
    }
}

public final class IconButton: Control {
    public var icon: Icon { didSet { needsDisplay = true } }
    public var transparent = false
    /// For a pair like undo and redo that share one glyph.
    public var mirrored = false

    public init(_ icon: Icon, transparent: Bool = false, action: (() -> Void)? = nil) {
        self.icon = icon
        self.transparent = transparent
        super.init(frame: .zero)
        onClick = action
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

    public override func draw(_ dirty: NSRect) {
        if !transparent || hovering {
            fillColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusControl,
                         yRadius: Theme.radiusControl).fill()
        }
        let s: CGFloat = 15
        NSGraphicsContext.saveGraphicsState()
        if mirrored {
            let flip = NSAffineTransform()
            flip.translateX(by: bounds.midX, yBy: 0)
            flip.scaleX(by: -1, yBy: 1)
            flip.translateX(by: -bounds.midX, yBy: 0)
            flip.concat()
        }
        icon.draw(in: NSRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2, width: s, height: s),
                  color: isEnabled ? Theme.icon : Theme.textTertiary)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Transport glyphs are drawn, not loaded: the icon library has no media set.
public final class TransportButton: Control {
    public enum Glyph { case play, pause, back, forward }
    public var glyph: Glyph { didSet { needsDisplay = true } }
    /// The play button is the one inverted control in the transport.
    public var prominent = false

    public init(_ glyph: Glyph, prominent: Bool = false, action: (() -> Void)? = nil) {
        self.glyph = glyph
        self.prominent = prominent
        super.init(frame: .zero)
        onClick = action
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }

    public override func draw(_ dirty: NSRect) {
        let bg = prominent ? Theme.textStrong : fillColor
        bg.withAlphaComponent(prominent && hovering ? 0.85 : 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusControl,
                     yRadius: Theme.radiusControl).fill()

        let ink = prominent ? Theme.canvas : Theme.icon
        ink.setFill()
        ink.setStroke()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)

        switch glyph {
        case .play:
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x - 4, y: c.y - 6))
            p.line(to: NSPoint(x: c.x + 6, y: c.y))
            p.line(to: NSPoint(x: c.x - 4, y: c.y + 6))
            p.close()
            p.fill()
        case .pause:
            NSBezierPath(roundedRect: NSRect(x: c.x - 5, y: c.y - 6, width: 3.5, height: 12),
                         xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: c.x + 1.5, y: c.y - 6, width: 3.5, height: 12),
                         xRadius: 1, yRadius: 1).fill()
        case .back, .forward:
            // A circular arrow with the skip amount inside, like the reference.
            let dir: CGFloat = glyph == .back ? -1 : 1
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 7,
                          startAngle: glyph == .back ? 200 : -20,
                          endAngle: glyph == .back ? 520 - 70 : -340 + 70,
                          clockwise: glyph == .forward)
            arc.lineWidth = 1.4
            arc.stroke()
            let tip = NSPoint(x: c.x - 7 * dir * 0.34, y: c.y - 7 * 0.94)
            let head = NSBezierPath()
            head.move(to: NSPoint(x: tip.x + 3.5 * dir, y: tip.y - 2))
            head.line(to: tip)
            head.line(to: NSPoint(x: tip.x + 3 * dir, y: tip.y + 2.5))
            head.lineWidth = 1.4
            head.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .semibold),
                .foregroundColor: ink,
            ]
            let s = ("5" as NSString).size(withAttributes: attrs)
            ("5" as NSString).draw(at: NSPoint(x: c.x - s.width / 2, y: c.y - s.height / 2 + 0.5),
                                   withAttributes: attrs)
        }
    }
}

/// Small filled label: "Group", "EP 1", an app name with its icon.
public final class Chip: ThemedView {
    public var text: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var image: NSImage?

    public init(_ text: String, image: NSImage? = nil) {
        self.text = text
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        let w = (text as NSString).size(withAttributes: [.font: Theme.Text.caption.font]).width
        return NSSize(width: ceil(w) + 16 + (image == nil ? 0 : 18), height: 22)
    }

    public override func draw(_ dirty: NSRect) {
        Theme.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusControl,
                     yRadius: Theme.radiusControl).fill()
        var x: CGFloat = 8
        if let image {
            image.draw(in: NSRect(x: x, y: bounds.midY - 7, width: 14, height: 14))
            x += 18
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.caption.font,
                                                    .foregroundColor: Theme.textSecondary]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: x, y: bounds.midY - s.height / 2), withAttributes: attrs)
    }
}

public final class Tabs: ThemedView {
    public var items: [String]
    public var selected: Int { didSet { needsDisplay = true } }
    public var onSelect: ((Int) -> Void)?
    private var frames: [NSRect] = []

    public init(_ items: [String], selected: Int = 0) {
        self.items = items
        self.selected = selected
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        let w = items.reduce(CGFloat(0)) {
            $0 + (($1 as NSString).size(withAttributes: [.font: Theme.Text.bodyStrong.font]).width + 20)
        }
        return NSSize(width: ceil(w) + CGFloat(items.count - 1) * 2, height: 26)
    }

    public override func draw(_ dirty: NSRect) {
        frames = []
        var x: CGFloat = 0
        for (i, item) in items.enumerated() {
            let font = i == selected ? Theme.Text.bodyStrong.font : Theme.Text.body.font
            let w = (item as NSString).size(withAttributes: [.font: Theme.Text.bodyStrong.font]).width + 20
            let r = NSRect(x: x, y: 0, width: w, height: bounds.height)
            frames.append(r)
            if i == selected {
                Theme.fill.setFill()
                NSBezierPath(roundedRect: r, xRadius: Theme.radiusControl,
                             yRadius: Theme.radiusControl).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: i == selected ? Theme.textPrimary : Theme.textSecondary,
            ]
            let s = (item as NSString).size(withAttributes: attrs)
            (item as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2),
                                    withAttributes: attrs)
            x += w + 2
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = frames.firstIndex(where: { $0.contains(p) }), i != selected else { return }
        selected = i
        onSelect?(i)
    }
}

public final class Switch: Control {
    public var isOn: Bool { didSet { needsDisplay = true } }
    public var onChange: ((Bool) -> Void)?

    public init(_ isOn: Bool) {
        self.isOn = isOn
        super.init(frame: .zero)
        onClick = { [weak self] in
            guard let self else { return }
            self.isOn.toggle()
            self.onChange?(self.isOn)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 18) }

    public override func draw(_ dirty: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 18) / 2, width: 30, height: 18)
        (isOn ? Theme.accent : Theme.track).setFill()
        NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9).fill()
        let knob = NSRect(x: isOn ? track.maxX - 16 : track.minX + 2, y: track.minY + 2,
                          width: 14, height: 14)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A filled pill that opens a menu. Accent border while its menu is open,
/// which is the focused state in the light reference.
public final class Dropdown: Control {
    public var options: [String]
    public var selected: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var onChange: ((String) -> Void)?
    public var focused = false { didSet { needsDisplay = true } }
    private var open = false

    public init(_ options: [String], selected: String, onChange: ((String) -> Void)? = nil) {
        self.options = options
        self.selected = selected
        self.onChange = onChange
        super.init(frame: .zero)
        onClick = { [weak self] in self?.showMenu() }
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        let w = options.map { ($0 as NSString).size(withAttributes: [.font: Theme.Text.body.font]).width }
            .max() ?? 40
        return NSSize(width: ceil(w) + 44, height: 28)
    }

    public override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusControl, yRadius: Theme.radiusControl)
        let lit = open || focused
        (lit ? Theme.canvas : fillColor).setFill()
        path.fill()
        if lit {
            path.lineWidth = Theme.borderSelected
            Theme.accentBorder.setStroke()
            path.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.body.font,
                                                    .foregroundColor: Theme.textPrimary]
        let s = (selected as NSString).size(withAttributes: attrs)
        (selected as NSString).draw(at: NSPoint(x: 12, y: bounds.midY - s.height / 2), withAttributes: attrs)
        Icon.chevronDown.draw(in: NSRect(x: bounds.maxX - 22, y: bounds.midY - 5, width: 10, height: 10),
                              color: Theme.icon)
    }

    private func showMenu() {
        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(title: option, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.state = option == selected ? .on : .off
            menu.addItem(item)
        }
        open = true
        needsDisplay = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        open = false
        needsDisplay = true
    }

    @objc private func pick(_ item: NSMenuItem) {
        selected = item.title
        onChange?(item.title)
    }
}

/// Label, track and value in one filled pill: "Desktop Audio ——●—— 80%".
public final class SliderPill: ThemedView {
    public let title: String
    public var value: Double { didSet { needsDisplay = true } }
    public let range: ClosedRange<Double>
    public var format: (Double) -> String
    public var onChange: ((Double) -> Void)?
    private var trackRect = NSRect.zero

    public init(_ title: String, value: Double, range: ClosedRange<Double> = 0...1,
                format: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }) {
        self.title = title
        self.value = value
        self.range = range
        self.format = format
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    public override func draw(_ dirty: NSRect) {
        Theme.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusControl, yRadius: Theme.radiusControl).fill()

        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.body.font,
                                                    .foregroundColor: Theme.textPrimary]
        let ts = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 12, y: bounds.midY - ts.height / 2), withAttributes: attrs)

        let valueText = format(value)
        let vattrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.meta.font,
                                                     .foregroundColor: Theme.textPrimary]
        let vs = (valueText as NSString).size(withAttributes: vattrs)
        (valueText as NSString).draw(at: NSPoint(x: bounds.maxX - 12 - vs.width, y: bounds.midY - vs.height / 2),
                                     withAttributes: vattrs)

        let x0 = 12 + ts.width + 16
        let x1 = bounds.maxX - 12 - max(vs.width, 34) - 14
        trackRect = NSRect(x: x0, y: bounds.midY - 2, width: max(x1 - x0, 20), height: 4)
        Theme.track.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2).fill()

        let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        let filled = NSRect(x: trackRect.minX, y: trackRect.minY, width: trackRect.width * f, height: 4)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()

        let knob = NSRect(x: filled.maxX - 7, y: bounds.midY - 7, width: 14, height: 14)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        Theme.accent.setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 2, dy: 2))
        ring.lineWidth = 3
        ring.stroke()
    }

    public override func mouseDown(with event: NSEvent) { track(event) }
    public override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        guard trackRect.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let f = min(max(Double((x - trackRect.minX) / trackRect.width), 0), 1)
        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
        onChange?(value)
    }
}

/// Icon plus a caption, heading a group of controls.
public final class SectionHeader: ThemedView {
    let text: String
    let icon: Icon?

    public init(_ text: String, icon: Icon? = nil) {
        self.text = text
        self.icon = icon
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    public override func draw(_ dirty: NSRect) {
        var x: CGFloat = 0
        if let icon {
            icon.draw(in: NSRect(x: 0, y: bounds.midY - 6.5, width: 13, height: 13), color: Theme.icon)
            x = 20
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.body.font,
                                                    .foregroundColor: Theme.textSecondary]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: x, y: bounds.midY - s.height / 2), withAttributes: attrs)
    }
}

/// Number field you can drag: the label is the handle, the way inspectors work.
public final class ScrubField: ThemedView {
    private let name: String
    public var value: Double { didSet { needsDisplay = true } }
    public let range: ClosedRange<Double>
    public let step: Double
    public var onChange: ((Double) -> Void)?
    private var dragStart: CGFloat = 0
    private var startValue: Double = 0

    public init(_ name: String, value: Double, range: ClosedRange<Double>, step: Double = 0.05) {
        self.name = name
        self.value = value
        self.range = range
        self.step = step
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    private var text: String { step >= 1 ? String(Int(value.rounded())) : String(format: "%.2f", value) }

    public override func draw(_ dirty: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.body.font,
                                                    .foregroundColor: Theme.textSecondary]
        let s = (name as NSString).size(withAttributes: attrs)
        (name as NSString).draw(at: NSPoint(x: 0, y: bounds.midY - s.height / 2), withAttributes: attrs)

        let box = NSRect(x: bounds.maxX - 64, y: bounds.midY - 12, width: 64, height: 24)
        Theme.fill.setFill()
        NSBezierPath(roundedRect: box, xRadius: Theme.radiusControl, yRadius: Theme.radiusControl).fill()
        let vattrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.meta.font,
                                                     .foregroundColor: Theme.textPrimary]
        let vs = (text as NSString).size(withAttributes: vattrs)
        (text as NSString).draw(at: NSPoint(x: box.maxX - 9 - vs.width, y: box.midY - vs.height / 2),
                                withAttributes: vattrs)
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    public override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil).x
        startValue = value
    }

    public override func mouseDragged(with event: NSEvent) {
        let dx = convert(event.locationInWindow, from: nil).x - dragStart
        let raw = startValue + Double(dx / 4) * step
        value = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
        onChange?(value)
    }
}
