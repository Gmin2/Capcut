import AppKit

/// Cutaway's own icons, drawn rather than imported.
///
/// Every one is built on a 20 by 20 grid with a 1.7 stroke, round caps and
/// round joins, so the whole set shares a weight and a rhythm no matter what
/// size it is drawn at. Shapes are deliberately plain: a rounded rectangle, a
/// circle, a straight line. That keeps them legible at 14 points, which is
/// where most of them live.
public enum Icon: String, CaseIterable {
    case chevronDown, chevronLeft, chevronRight
    case gear, mic, micOff, camera, volume, keyboard, display, area
    case scissors, zoom, plus, trash, folder, download, sidebar, expand
    case layers, transcript, bookmark, undo
    case pointer, arrowTool, square, shapes, textTool, highlight, droplet
    case numbered, image, ratio, pen
    case copy, check

    /// The grid every icon is drawn on.
    static let grid: CGFloat = 20
    static let stroke: CGFloat = 1.7

    public func draw(in rect: NSRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(rect.width, rect.height) / Icon.grid
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - Icon.grid * scale / 2,
                        y: rect.midY - Icon.grid * scale / 2)
        ctx.scaleBy(x: scale, y: scale)
        // Icons are described top-down, the way they are drawn on paper. Most
        // of the app's views are already flipped, so only flip when they are not.
        if NSGraphicsContext.current?.isFlipped != true {
            ctx.translateBy(x: 0, y: Icon.grid)
            ctx.scaleBy(x: 1, y: -1)
        }

        color.setStroke()
        color.setFill()
        let ink = Ink()
        shape(ink)
        ink.strokePath.lineWidth = Icon.stroke
        ink.strokePath.lineCapStyle = .round
        ink.strokePath.lineJoinStyle = .round
        ink.strokePath.stroke()
        ink.fillPath.fill()
        ctx.restoreGState()
    }

    /// Two paths: one stroked, one filled. Most icons only use the first.
    final class Ink {
        let strokePath = NSBezierPath()
        let fillPath = NSBezierPath()

        func line(_ a: CGPoint, _ b: CGPoint) {
            strokePath.move(to: a)
            strokePath.line(to: b)
        }

        func poly(_ points: [CGPoint], close: Bool = false) {
            guard let first = points.first else { return }
            strokePath.move(to: first)
            for p in points.dropFirst() { strokePath.line(to: p) }
            if close { strokePath.close() }
        }

        func rect(_ r: NSRect, radius: CGFloat = 3) {
            strokePath.append(NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius))
        }

        func circle(_ centre: CGPoint, _ r: CGFloat) {
            strokePath.append(NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r,
                                                          width: r * 2, height: r * 2)))
        }

        func dot(_ centre: CGPoint, _ r: CGFloat) {
            fillPath.append(NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r,
                                                        width: r * 2, height: r * 2)))
        }

        func blob(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            fillPath.move(to: first)
            for p in points.dropFirst() { fillPath.line(to: p) }
            fillPath.close()
        }

        func arc(_ centre: CGPoint, _ r: CGFloat, from: CGFloat, to: CGFloat) {
            strokePath.appendArc(withCenter: centre, radius: r, startAngle: from, endAngle: to)
        }
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // swiftlint:disable:next cyclomatic_complexity
    private func shape(_ ink: Ink) {
        switch self {
        case .chevronDown:  ink.poly([p(5, 8), p(10, 13), p(15, 8)])
        case .chevronLeft:  ink.poly([p(12.5, 4.5), p(7.5, 10), p(12.5, 15.5)])
        case .chevronRight: ink.poly([p(7.5, 4.5), p(12.5, 10), p(7.5, 15.5)])

        case .gear:
            // two sliders rather than a cogwheel: settings here are values to
            // set, and a cog turns to mush below 16 points
            ink.line(p(3.4, 7.4), p(16.6, 7.4))
            ink.line(p(3.4, 12.6), p(16.6, 12.6))
            ink.circle(p(7.6, 7.4), 2.1)
            ink.circle(p(12.4, 12.6), 2.1)

        case .mic:
            ink.rect(NSRect(x: 7.4, y: 2.6, width: 5.2, height: 9), radius: 2.6)
            ink.arc(p(10, 10.4), 4.6, from: 200, to: 340)
            ink.line(p(10, 15), p(10, 17.4))

        case .micOff:
            ink.rect(NSRect(x: 7.4, y: 2.6, width: 5.2, height: 9), radius: 2.6)
            ink.arc(p(10, 10.4), 4.6, from: 200, to: 340)
            ink.line(p(10, 15), p(10, 17.4))
            ink.line(p(3.4, 3.4), p(16.6, 16.6))

        case .camera:
            ink.rect(NSRect(x: 2.6, y: 5.4, width: 10, height: 9), radius: 2.4)
            ink.poly([p(13.4, 9), p(17.4, 6.6), p(17.4, 13.4), p(13.4, 11)], close: true)

        case .volume:
            ink.poly([p(3, 8), p(6, 8), p(9.8, 4.6), p(9.8, 15.4), p(6, 12), p(3, 12)], close: true)
            ink.arc(p(10.6, 10), 3.6, from: -52, to: 52)
            ink.arc(p(10.6, 10), 6.4, from: -46, to: 46)

        case .keyboard:
            ink.rect(NSRect(x: 2.4, y: 5.4, width: 15.2, height: 9.2), radius: 2.4)
            for x in stride(from: 5.2, through: 11.2, by: 3) { ink.dot(p(x, 9), 0.75) }
            ink.dot(p(14.4, 9), 0.75)
            ink.line(p(6.4, 12.4), p(13.6, 12.4))

        case .display:
            ink.rect(NSRect(x: 2.4, y: 3.6, width: 15.2, height: 10.4), radius: 2.4)
            ink.line(p(7, 17), p(13, 17))
            ink.line(p(10, 14), p(10, 17))

        case .area:
            // a dashed frame: the shape of a drag-out selection
            for (a, b) in [(p(3, 5), p(3, 15)), (p(17, 5), p(17, 15)),
                           (p(5, 3), p(15, 3)), (p(5, 17), p(15, 17))] {
                ink.line(a, b)
            }
            ink.dot(p(3, 3), 0.9)
            ink.dot(p(17, 3), 0.9)
            ink.dot(p(3, 17), 0.9)
            ink.dot(p(17, 17), 0.9)

        case .scissors:
            ink.circle(p(5.4, 14.6), 2.4)
            ink.circle(p(14.6, 14.6), 2.4)
            ink.line(p(6.9, 12.7), p(15, 3.4))
            ink.line(p(13.1, 12.7), p(5, 3.4))

        case .zoom:
            ink.circle(p(9, 9), 5.4)
            ink.line(p(13, 13), p(17, 17))
            ink.line(p(6.6, 9), p(11.4, 9))
            ink.line(p(9, 6.6), p(9, 11.4))

        case .plus:
            ink.line(p(10, 4.4), p(10, 15.6))
            ink.line(p(4.4, 10), p(15.6, 10))

        case .trash:
            ink.line(p(3.4, 5.6), p(16.6, 5.6))
            ink.poly([p(5.4, 5.6), p(6.2, 16.4), p(13.8, 16.4), p(14.6, 5.6)])
            ink.poly([p(7.6, 5.6), p(7.6, 3.6), p(12.4, 3.6), p(12.4, 5.6)])

        case .folder:
            ink.poly([p(2.8, 15.8), p(2.8, 5), p(8, 5), p(9.6, 7.2), p(17.2, 7.2),
                      p(17.2, 15.8)], close: true)

        case .download:
            ink.line(p(10, 3.4), p(10, 12.6))
            ink.poly([p(6.2, 9), p(10, 12.8), p(13.8, 9)])
            ink.line(p(4, 16.4), p(16, 16.4))

        case .sidebar:
            ink.rect(NSRect(x: 2.6, y: 3.6, width: 14.8, height: 12.8), radius: 2.6)
            ink.line(p(13, 3.6), p(13, 16.4))

        case .expand:
            ink.poly([p(3.4, 8), p(3.4, 3.4), p(8, 3.4)])
            ink.poly([p(12, 16.6), p(16.6, 16.6), p(16.6, 12)])
            ink.line(p(3.4, 3.4), p(8.4, 8.4))
            ink.line(p(16.6, 16.6), p(11.6, 11.6))

        case .layers:
            ink.poly([p(10, 2.8), p(17.4, 7), p(10, 11.2), p(2.6, 7)], close: true)
            ink.poly([p(3.8, 10.6), p(10, 14.2), p(16.2, 10.6)])
            ink.poly([p(3.8, 13.8), p(10, 17.4), p(16.2, 13.8)])

        case .transcript:
            ink.rect(NSRect(x: 3.4, y: 2.8, width: 13.2, height: 14.4), radius: 2.4)
            ink.line(p(6.4, 7), p(13.6, 7))
            ink.line(p(6.4, 10), p(13.6, 10))
            ink.line(p(6.4, 13), p(10.6, 13))

        case .bookmark:
            ink.poly([p(5.2, 2.8), p(14.8, 2.8), p(14.8, 17.2), p(10, 13), p(5.2, 17.2)],
                     close: true)

        case .undo:
            // a loop back to the left, with the head where the motion ends
            ink.arc(p(10.4, 11), 5.4, from: 172, to: 8)
            // the head sits on the arc's left end, pointing back the way it came
            ink.poly([p(2.6, 9.4), p(5.1, 12.1), p(7.6, 9.6)])

        case .pointer:
            ink.poly([p(5, 3), p(15.4, 10.2), p(10.6, 11), p(12.6, 16.2), p(10.2, 17),
                      p(8.2, 11.9), p(5, 15)], close: true)

        case .arrowTool:
            ink.line(p(4.6, 15.4), p(15.4, 4.6))
            ink.poly([p(8.4, 4.6), p(15.4, 4.6), p(15.4, 11.6)])

        case .square:
            ink.rect(NSRect(x: 3.6, y: 4.6, width: 12.8, height: 10.8), radius: 2.4)

        case .shapes:
            ink.circle(p(10, 10), 6.2)

        case .textTool:
            ink.line(p(4.4, 4.6), p(15.6, 4.6))
            ink.line(p(10, 4.6), p(10, 15.4))
            ink.line(p(7, 15.4), p(13, 15.4))

        case .highlight:
            ink.poly([p(4.4, 12.4), p(11.6, 5.2), p(14.8, 8.4), p(7.6, 15.6), p(4.4, 15.6)],
                     close: true)
            ink.line(p(11.4, 15.6), p(16.6, 15.6))

        case .droplet:
            // the blur tool: a drop over a blurred row of squares
            ink.poly([p(10, 3.2), p(14.6, 9.4)])
            ink.arc(p(10, 11.4), 4.6, from: -55, to: 235)
            ink.line(p(10, 3.2), p(5.4, 9.4))

        case .numbered:
            // a numbered step: the badge Cutaway actually draws, plus its rows
            ink.circle(p(5.4, 5.6), 2.8)
            ink.line(p(5.4, 4.2), p(5.4, 7))
            ink.line(p(10.4, 5.6), p(16.6, 5.6))
            ink.line(p(3.4, 11.4), p(16.6, 11.4))
            ink.line(p(3.4, 16), p(13, 16))

        case .image:
            ink.rect(NSRect(x: 2.8, y: 4, width: 14.4, height: 12), radius: 2.4)
            ink.poly([p(3.4, 13.4), p(7.6, 9.4), p(11, 12.6), p(13.6, 10.2), p(16.6, 13)])
            ink.dot(p(7.4, 7.6), 1.1)

        case .ratio:
            // a wide frame with a narrow one inside: one shape into another
            ink.rect(NSRect(x: 2.6, y: 4.4, width: 14.8, height: 11.2), radius: 2.4)
            ink.rect(NSRect(x: 6.4, y: 7.4, width: 7.2, height: 5.2), radius: 1.6)

        case .copy:
            ink.rect(NSRect(x: 3, y: 3, width: 10.4, height: 10.4), radius: 2.4)
            ink.poly([p(7, 16.8), p(16.8, 16.8), p(16.8, 7)])

        case .check:
            ink.poly([p(4, 10.6), p(8.2, 14.8), p(16, 5.6)])

        case .pen:
            ink.poly([p(3.2, 16.8), p(4.4, 12.8), p(13.4, 3.8), p(16.2, 6.6), p(7.2, 15.6)],
                     close: true)
            ink.line(p(11.6, 5.6), p(14.4, 8.4))
        }
    }

    /// A template image of the icon, for the few places AppKit wants one.
    public var image: NSImage? {
        let size = NSSize(width: Icon.grid, height: Icon.grid)
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }
}
