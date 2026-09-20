import AppKit
import CoreImage

/// Marking up a capture: arrows, boxes, text, blur, numbered steps.
///
/// Marks are kept in image pixel coordinates, never in view coordinates, so
/// the export is the same drawing at full resolution rather than a scaled
/// screenshot of the canvas.
public enum Tool: String, CaseIterable {
    case select, arrow, box, ellipse, highlight, blur, text, step

    var icon: Icon {
        switch self {
        case .select: return .pointer
        case .arrow: return .arrowTool
        case .box: return .square
        case .ellipse: return .shapes
        case .highlight: return .highlight
        case .blur: return .droplet
        case .text: return .textTool
        case .step: return .numbered
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .box: return "Box"
        case .ellipse: return "Ellipse"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .text: return "Text"
        case .step: return "Step"
        }
    }

    /// Tools placed with a single click rather than dragged out.
    var isStamp: Bool { self == .text || self == .step }
}

public struct Mark {
    var tool: Tool
    /// Image pixels. For an arrow this is the drag, so it keeps its direction.
    var from: CGPoint
    var to: CGPoint
    var color: NSColor
    var width: CGFloat
    var text = ""
    var number = 0

    var rect: CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
               width: abs(to.x - from.x), height: abs(to.y - from.y))
    }

    /// What counts as a hit, and what gets dragged around.
    func bounds(scale: CGFloat) -> CGRect {
        switch tool {
        case .arrow:
            return rect.insetBy(dx: -width * 2, dy: -width * 2)
        case .text:
            let size = (text as NSString).size(withAttributes: [.font: Mark.font(width)])
            return CGRect(x: from.x, y: from.y, width: max(size.width, 20), height: size.height)
        case .step:
            let r = Mark.stepRadius(width)
            return CGRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)
        default:
            return rect.insetBy(dx: -width, dy: -width)
        }
    }

    static func font(_ width: CGFloat) -> NSFont {
        .systemFont(ofSize: max(14, width * 7), weight: .semibold)
    }

    static func stepRadius(_ width: CGFloat) -> CGFloat { max(14, width * 6) }
}

/// The dressing around the shot: a background, breathing room, rounded
/// corners and a shadow. Sizes are in image pixels so the export matches.
public struct Frame {
    public var padding: CGFloat = 0
    public var corner: CGFloat = 0
    public var shadow: Double = 0.35
    public var background = Background.plain(NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))

    public enum Background {
        case plain(NSColor)
        case gradient(NSColor, NSColor)

        var swatch: NSColor {
            switch self {
            case .plain(let c): return c
            case .gradient(let a, _): return a
            }
        }

        func fill(_ rect: NSRect) {
            switch self {
            case .plain(let c):
                c.setFill()
                rect.fill()
            case .gradient(let a, let b):
                NSGradient(starting: a, ending: b)?.draw(in: rect, angle: -45)
            }
        }
    }

    /// The presets the grid offers, gradients first because they look best.
    public static let presets: [Background] = [
        .gradient(NSColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
                  NSColor(srgbRed: 0.93, green: 0.29, blue: 0.47, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.35, green: 0.67, blue: 0.97, alpha: 1),
                  NSColor(srgbRed: 0.45, green: 0.35, blue: 0.93, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.35, green: 0.87, blue: 0.72, alpha: 1),
                  NSColor(srgbRed: 0.20, green: 0.55, blue: 0.68, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.99, green: 0.85, blue: 0.51, alpha: 1),
                  NSColor(srgbRed: 0.95, green: 0.52, blue: 0.31, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.24, green: 0.24, blue: 0.30, alpha: 1),
                  NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)),
        .gradient(NSColor(srgbRed: 0.85, green: 0.86, blue: 0.92, alpha: 1),
                  NSColor(srgbRed: 0.98, green: 0.94, blue: 0.93, alpha: 1)),
        .plain(NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)),
        .plain(.white),
        .plain(NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)),
        .plain(NSColor(srgbRed: 0.96, green: 0.91, blue: 0.85, alpha: 1)),
        .plain(NSColor(srgbRed: 0.84, green: 0.91, blue: 0.87, alpha: 1)),
        .plain(NSColor(srgbRed: 0.87, green: 0.89, blue: 0.96, alpha: 1)),
        .plain(NSColor(srgbRed: 0.97, green: 0.87, blue: 0.87, alpha: 1)),
        .plain(NSColor(srgbRed: 0.20, green: 0.28, blue: 0.36, alpha: 1)),
    ]
}

// MARK: - drawing

/// Draws marks into whatever context is current. Used for both the canvas and
/// the export, so what you see is what lands in the file.
enum MarkRenderer {

    static func draw(_ marks: [Mark], selected: Int?, pixelated: CGImage?,
                     imageSize: CGSize, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = rect.width / imageSize.width

        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: scale, y: scale)
        // image pixels have their origin top left, the context bottom left
        ctx.translateBy(x: 0, y: imageSize.height)
        ctx.scaleBy(x: 1, y: -1)

        for (i, m) in marks.enumerated() {
            draw(m, pixelated: pixelated, imageSize: imageSize)
            if i == selected { drawSelection(m) }
        }
        ctx.restoreGState()
    }

    private static func draw(_ m: Mark, pixelated: CGImage?, imageSize: CGSize) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch m.tool {
        case .box:
            let p = NSBezierPath(roundedRect: m.rect, xRadius: m.width, yRadius: m.width)
            p.lineWidth = m.width
            m.color.setStroke()
            p.stroke()

        case .ellipse:
            let p = NSBezierPath(ovalIn: m.rect)
            p.lineWidth = m.width
            m.color.setStroke()
            p.stroke()

        case .highlight:
            m.color.withAlphaComponent(0.32).setFill()
            ctx.setBlendMode(.multiply)
            NSBezierPath(rect: m.rect).fill()
            ctx.setBlendMode(.normal)

        case .blur:
            guard let pixelated else { break }
            ctx.saveGState()
            ctx.clip(to: m.rect)
            ctx.draw(pixelated, in: CGRect(origin: .zero, size: imageSize))
            ctx.restoreGState()

        case .arrow:
            drawArrow(m)

        case .text:
            let attrs: [NSAttributedString.Key: Any] = [.font: Mark.font(m.width),
                                                        .foregroundColor: m.color]
            let shown = m.text.isEmpty ? "Text" : m.text
            ctx.saveGState()
            // text is the one thing that must not be drawn upside down
            ctx.translateBy(x: m.from.x, y: m.from.y)
            ctx.scaleBy(x: 1, y: -1)
            (shown as NSString).draw(at: NSPoint(x: 0, y: -Mark.font(m.width).ascender),
                                     withAttributes: attrs)
            ctx.restoreGState()

        case .step:
            let r = Mark.stepRadius(m.width)
            let circle = NSBezierPath(ovalIn: CGRect(x: m.from.x - r, y: m.from.y - r,
                                                     width: r * 2, height: r * 2))
            m.color.setFill()
            circle.fill()
            let label = "\(m.number)" as NSString
            let font = NSFont.systemFont(ofSize: r * 1.1, weight: .bold)
            let size = label.size(withAttributes: [.font: font])
            ctx.saveGState()
            ctx.translateBy(x: m.from.x, y: m.from.y)
            ctx.scaleBy(x: 1, y: -1)
            label.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
            ctx.restoreGState()

        case .select:
            break
        }
    }

    private static func drawArrow(_ m: Mark) {
        let dx = m.to.x - m.from.x, dy = m.to.y - m.from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let head = min(max(m.width * 4, 14), length * 0.5)
        let angle = atan2(dy, dx)

        // the shaft stops short so the head has a clean point
        let stop = CGPoint(x: m.to.x - cos(angle) * head * 0.7,
                           y: m.to.y - sin(angle) * head * 0.7)
        let shaft = NSBezierPath()
        shaft.move(to: m.from)
        shaft.line(to: stop)
        shaft.lineWidth = m.width
        shaft.lineCapStyle = .round
        m.color.setStroke()
        shaft.stroke()

        let spread = CGFloat.pi / 7
        let tip = NSBezierPath()
        tip.move(to: m.to)
        tip.line(to: CGPoint(x: m.to.x - cos(angle - spread) * head,
                             y: m.to.y - sin(angle - spread) * head))
        tip.line(to: CGPoint(x: m.to.x - cos(angle + spread) * head,
                             y: m.to.y - sin(angle + spread) * head))
        tip.close()
        m.color.setFill()
        tip.fill()
    }

    private static func drawSelection(_ m: Mark) {
        let b = m.bounds(scale: 1).insetBy(dx: -4, dy: -4)
        let p = NSBezierPath(rect: b)
        p.lineWidth = 1.5
        p.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        p.stroke()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        p.setLineDash([6, 4], count: 2, phase: 6)
        p.stroke()
    }
}

/// The background, the rounded picture and its shadow. Shared by the canvas
/// and the export so both agree.
enum FrameRenderer {
    static func draw(image: CGImage, frame: Frame, in rect: NSRect, imageRect: NSRect,
                     scale: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if frame.padding > 0 { frame.background.fill(rect) }

        let radius = frame.corner * scale
        let clip = NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius)
        if frame.shadow > 0.01, frame.padding > 0 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(CGFloat(frame.shadow) * 0.7)
            shadow.shadowBlurRadius = 30 * scale * CGFloat(frame.shadow) + 6
            shadow.shadowOffset = NSSize(width: 0, height: -10 * scale * CGFloat(frame.shadow))
            shadow.set()
            NSColor.black.setFill()
            clip.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        ctx.draw(image, in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - canvas

final class AnnotateCanvas: ThemedView {
    var image: CGImage? { didSet { pixelated = nil; needsDisplay = true } }
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true } }
    var tool = Tool.select
    var color = NSColor.systemRed
    var width: CGFloat = 4
    var dressing = Frame() { didSet { needsDisplay = true } }
    /// Set while the crop tool is up: the part being kept, in image pixels.
    var cropping: CGRect? { didSet { needsDisplay = true } }
    var isCropping = false { didSet { cropping = nil; needsDisplay = true } }

    var onCommit: ((Mark) -> Void)?
    var onChange: (([Mark], Int?) -> Void)?
    var onBeginEdit: ((Int) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    private var draft: Mark?
    private var cropStart: CGPoint?
    private var dragStart: CGPoint?
    private var dragOrigin: (from: CGPoint, to: CGPoint)?
    private var pixelated: CGImage?

    override var isFlipped: Bool { false }

    var imageSize: CGSize {
        guard let image else { return CGSize(width: 1, height: 1) }
        return CGSize(width: image.width, height: image.height)
    }

    /// Picture plus its padding: what the export is made of.
    var contentSize: CGSize {
        CGSize(width: imageSize.width + dressing.padding * 2,
               height: imageSize.height + dressing.padding * 2)
    }

    /// The whole framed thing inside the canvas, fitted with a margin.
    var frameRect: NSRect {
        let box = bounds.insetBy(dx: 40, dy: 60)
        let s = min(box.width / contentSize.width, box.height / contentSize.height, 1)
        let w = contentSize.width * s, h = contentSize.height * s
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h).integral
    }

    /// Where the picture itself sits, inside the padding.
    var imageRect: NSRect {
        let r = frameRect
        let s = r.width / contentSize.width
        return r.insetBy(dx: dressing.padding * s, dy: dressing.padding * s).integral
    }

    override func draw(_ dirty: NSRect) {
        Theme.canvas.setFill()
        bounds.fill()
        drawDots()
        guard let image else { return }

        let scale = frameRect.width / contentSize.width
        FrameRenderer.draw(image: image, frame: dressing, in: frameRect, imageRect: imageRect,
                           scale: scale)
        let all = draft.map { marks + [$0] } ?? marks
        // clipped to the picture, because the export is
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        MarkRenderer.draw(all, selected: selected, pixelated: pixelatedImage(),
                          imageSize: imageSize, in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
        if isCropping { drawCrop() }
    }

    private func drawCrop() {
        let r = imageRect
        let keep = cropping.map { viewRect($0) } ?? r
        let shade = NSBezierPath(rect: r)
        shade.append(NSBezierPath(rect: keep))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        shade.fill()

        let outline = NSBezierPath(rect: keep)
        outline.lineWidth = 1.5
        Theme.accent.setStroke()
        outline.stroke()
        for p in [NSPoint(x: keep.minX, y: keep.minY), NSPoint(x: keep.maxX, y: keep.minY),
                  NSPoint(x: keep.minX, y: keep.maxY), NSPoint(x: keep.maxX, y: keep.maxY)] {
            let box = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(rect: box).fill()
            Theme.accent.setStroke()
            NSBezierPath(rect: box).stroke()
        }

        let size = cropping ?? CGRect(origin: .zero, size: imageSize)
        let label = "\(Int(size.width)) × \(Int(size.height))  ⏎ to crop" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white]
        let s = label.size(withAttributes: attrs)
        let pill = NSRect(x: keep.midX - s.width / 2 - 8, y: keep.minY - s.height - 14,
                          width: s.width + 16, height: s.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4), withAttributes: attrs)
    }

    /// Image pixels -> view points, the other way round from imagePoint.
    func viewRect(_ r: CGRect) -> NSRect {
        let box = imageRect
        let s = box.width / imageSize.width
        return NSRect(x: box.minX + r.minX * s, y: box.maxY - (r.minY + r.height) * s,
                      width: r.width * s, height: r.height * s)
    }

    /// Keeps the chosen part and moves every mark with it.
    func applyCrop() -> Bool {
        guard let image, var keep = cropping else { return false }
        keep = keep.integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard keep.width > 16, keep.height > 16, let cut = image.cropping(to: keep) else { return false }
        self.image = cut
        marks = marks.map {
            var m = $0
            m.from = CGPoint(x: m.from.x - keep.minX, y: m.from.y - keep.minY)
            m.to = CGPoint(x: m.to.x - keep.minX, y: m.to.y - keep.minY)
            return m
        }
        isCropping = false
        selected = nil
        return true
    }

    private func drawDots() {
        Theme.divider.setFill()
        let step: CGFloat = 22
        var y = bounds.minY + step / 2
        while y < bounds.maxY {
            var x = bounds.minX + step / 2
            while x < bounds.maxX {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill()
                x += step
            }
            y += step
        }
    }

    /// Built once per image: the blur tool just shows this through a clip.
    func pixelatedImage() -> CGImage? {
        if let pixelated { return pixelated }
        guard let image else { return nil }
        let ci = CIImage(cgImage: image)
        let scale = max(image.width, image.height) / 90
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(max(6, CGFloat(scale)), forKey: kCIInputScaleKey)
        guard let out = filter.outputImage,
              let made = CIContext().createCGImage(out, from: ci.extent) else { return nil }
        pixelated = made
        return made
    }

    // MARK: input

    /// View point -> image pixel, with the origin at the top left of the image.
    func imagePoint(_ p: NSPoint) -> CGPoint {
        let r = imageRect
        guard r.width > 0 else { return .zero }
        let s = imageSize.width / r.width
        return CGPoint(x: (p.x - r.minX) * s, y: (r.maxY - p.y) * s)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(convert(event.locationInWindow, from: nil))

        if isCropping {
            cropStart = p
            cropping = CGRect(origin: p, size: .zero)
            return
        }

        if tool == .select {
            selected = hit(p)
            if let i = selected {
                dragStart = p
                dragOrigin = (marks[i].from, marks[i].to)
                if event.clickCount == 2, marks[i].tool == .text { onBeginEdit?(i) }
            }
            return
        }

        if tool.isStamp {
            var m = Mark(tool: tool, from: p, to: p, color: color, width: width)
            if tool == .step { m.number = marks.filter { $0.tool == .step }.count + 1 }
            onCommit?(m)
            if tool == .text { onBeginEdit?(marks.count - 1) }
            return
        }
        draft = Mark(tool: tool, from: p, to: p, color: color, width: width)
    }

    /// Shift makes a box square, an ellipse round and an arrow snap to
    /// eighths of a turn, the way every drawing tool behaves.
    private func constrain(_ from: CGPoint, _ to: CGPoint, tool: Tool) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        if tool == .arrow {
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: from.x + cos(angle) * length, y: from.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: from.x + (dx < 0 ? -side : side), y: from.y + (dy < 0 ? -side : side))
    }

    override func mouseDragged(with event: NSEvent) {
        var p = imagePoint(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift), let d = draft {
            p = constrain(d.from, p, tool: d.tool)
        }
        if isCropping, let start = cropStart {
            cropping = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(p.x - start.x), height: abs(p.y - start.y))
            return
        }
        if var d = draft {
            d.to = p
            draft = d
            needsDisplay = true
            return
        }
        guard let i = selected, let start = dragStart, let origin = dragOrigin else { return }
        let dx = p.x - start.x, dy = p.y - start.y
        marks[i].from = CGPoint(x: origin.from.x + dx, y: origin.from.y + dy)
        marks[i].to = CGPoint(x: origin.to.x + dx, y: origin.to.y + dy)
        onChange?(marks, selected)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        dragOrigin = nil
        guard var d = draft else { return }
        if event.modifierFlags.contains(.shift) {
            d.to = constrain(d.from, imagePoint(convert(event.locationInWindow, from: nil)), tool: d.tool)
            draft = d
        }
        draft = nil
        // a stray click with a drag tool should not leave an invisible mark
        let size = max(abs(d.to.x - d.from.x), abs(d.to.y - d.from.y))
        guard size > 6 else { needsDisplay = true; return }
        onCommit?(d)
    }

    private func hit(_ p: CGPoint) -> Int? {
        for (i, m) in marks.enumerated().reversed() where m.bounds(scale: 1).contains(p) {
            return i
        }
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
