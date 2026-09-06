import AppKit

/// The look of the app.
///
/// Deliberately dark and low contrast: the preview is the subject, and every
/// pixel of chrome competes with it. Editors that people call premium are
/// mostly restraint plus consistent spacing.
public enum Theme {

    public static let background   = NSColor(calibratedWhite: 0.086, alpha: 1)
    public static let panel        = NSColor(calibratedWhite: 0.118, alpha: 1)
    public static let panelRaised  = NSColor(calibratedWhite: 0.153, alpha: 1)
    public static let stroke       = NSColor(calibratedWhite: 0.22, alpha: 1)
    public static let text         = NSColor(calibratedWhite: 0.93, alpha: 1)
    public static let textDim      = NSColor(calibratedWhite: 0.55, alpha: 1)
    public static let accent       = NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.30, alpha: 1)
    public static let recording    = NSColor(calibratedRed: 0.95, green: 0.29, blue: 0.27, alpha: 1)

    public static let corner: CGFloat = 8
    public static let gutter: CGFloat = 14

    public static func label(_ s: String, size: CGFloat = 12,
                             weight: NSFont.Weight = .regular,
                             color: NSColor = text) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        return f
    }

    public static func caption(_ s: String) -> NSTextField {
        let f = label(s.uppercased(), size: 9.5, weight: .semibold, color: textDim)
        // Uppercase micro-labels need tracking or they read as a smudge.
        f.attributedStringValue = NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: textDim,
            .kern: 0.9,
        ])
        return f
    }

    public static func mono(_ s: String, size: CGFloat = 11,
                            color: NSColor = textDim) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        f.textColor = color
        return f
    }
}

/// A flat button that matches the rest of the chrome. AppKit's push button
/// cannot be restyled far enough to sit in a dark editor without looking bolted
/// on, so this draws itself.
public final class FlatButton: NSButton {

    public enum Kind { case normal, primary, danger }

    public var kind: Kind = .normal { didSet { needsDisplay = true } }
    private var hovering = false

    public init(_ title: String, kind: Kind = .normal,
                target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.kind = kind
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 12, weight: .medium)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: font!]).width
        return NSSize(width: ceil(w) + 26, height: 26)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    public override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)

        let fill: NSColor
        switch kind {
        case .primary: fill = Theme.accent.withAlphaComponent(hovering ? 1 : 0.9)
        case .danger:  fill = Theme.recording.withAlphaComponent(hovering ? 1 : 0.9)
        case .normal:  fill = hovering ? Theme.panelRaised : Theme.panel
        }
        fill.setFill()
        path.fill()

        if kind == .normal {
            Theme.stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let colour = kind == .normal
            ? (isEnabled ? Theme.text : Theme.textDim)
            : NSColor.white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font!,
            .foregroundColor: isEnabled ? colour : colour.withAlphaComponent(0.4),
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2,
                        y: (bounds.height - size.height) / 2),
            withAttributes: attrs)
    }
}

/// Number field with a drag-to-change label, the way every editor's inspector
/// works. Typing is still possible; dragging is what people actually use.
public final class ScrubField: NSView {

    private let nameLabel: NSTextField
    private let field = NSTextField()
    private var dragStart: CGFloat = 0
    private var valueAtDragStart: Double = 0

    public var value: Double { didSet { field.stringValue = format(value) } }
    public let range: ClosedRange<Double>
    public let step: Double
    public var onChange: ((Double) -> Void)?

    public init(_ name: String, value: Double, range: ClosedRange<Double>,
                step: Double = 0.05) {
        self.nameLabel = Theme.caption(name)
        self.value = value
        self.range = range
        self.step = step
        super.init(frame: .zero)

        field.stringValue = format(value)
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.textColor = Theme.text
        field.backgroundColor = Theme.background
        field.isBordered = false
        field.drawsBackground = true
        field.alignment = .right
        field.focusRingType = .none
        field.target = self
        field.action = #selector(committed)

        [nameLabel, field].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 58),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func format(_ v: Double) -> String {
        step >= 1 ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }

    public override func resetCursorRects() {
        addCursorRect(nameLabel.frame.insetBy(dx: -4, dy: -6), cursor: .resizeLeftRight)
    }

    public override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil).x
        valueAtDragStart = value
    }

    public override func mouseDragged(with event: NSEvent) {
        let dx = convert(event.locationInWindow, from: nil).x - dragStart
        // Four pixels per step keeps a fine value reachable without the pointer
        // travelling the width of the panel.
        let raw = valueAtDragStart + Double(dx / 4) * step
        value = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
        onChange?(value)
    }

    @objc private func committed() {
        guard let v = Double(field.stringValue) else {
            field.stringValue = format(value)
            return
        }
        value = min(max(v, range.lowerBound), range.upperBound)
        onChange?(value)
    }
}
