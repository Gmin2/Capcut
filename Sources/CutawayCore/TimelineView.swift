import AppKit

/// The timeline strip: scenes on one lane, zooms on another, playhead over
/// both. Clicking or dragging seeks. Deliberately drawn rather than built from
/// subviews, because the number of blocks changes on every edit.
public final class TimelineView: NSView {

    public var duration: Double = 0 { didSet { needsDisplay = true } }
    public var timeline: Timeline? { didSet { needsDisplay = true } }
    public var playhead: Double = 0 { didSet { needsDisplay = true } }
    public var onSeek: ((Double) -> Void)?

    public override var isFlipped: Bool { true }

    private let laneHeight: CGFloat = 26
    private let laneGap: CGFloat = 6
    private let labelInset: CGFloat = 54

    public override func draw(_ dirty: NSRect) {
        guard duration > 0 else { return }
        let track = NSRect(x: labelInset, y: 0,
                           width: bounds.width - labelInset - 8, height: bounds.height)

        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()

        func x(_ t: Double) -> CGFloat {
            track.minX + track.width * CGFloat(min(max(t / duration, 0), 1))
        }

        // second ticks
        NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
        let path = NSBezierPath()
        var s = 0.0
        while s <= duration {
            path.move(to: NSPoint(x: x(s), y: 0))
            path.line(to: NSPoint(x: x(s), y: bounds.height))
            s += 1
        }
        path.lineWidth = 1
        path.stroke()

        // Cut spans, drawn under everything so kept material reads as solid.
        if let tl = timeline, !tl.timeMap.isIdentity {
            NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
            var prev = 0.0
            for s in tl.timeMap.segments {
                if s.sourceStart > prev {
                    NSRect(x: x(prev), y: 0, width: max(1, x(s.sourceStart) - x(prev)),
                           height: bounds.height).fill()
                }
                if s.speed > 1.01 {
                    NSColor(calibratedRed: 0.85, green: 0.72, blue: 0.25, alpha: 0.22).setFill()
                    NSRect(x: x(s.sourceStart), y: 0,
                           width: max(1, x(s.sourceEnd) - x(s.sourceStart)),
                           height: bounds.height).fill()
                    NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
                }
                prev = max(prev, s.sourceEnd)
            }
            if prev < duration {
                NSRect(x: x(prev), y: 0, width: max(1, x(duration) - x(prev)),
                       height: bounds.height).fill()
            }
        }

        drawLabel("scenes", y: laneGap)
        drawLabel("zoom", y: laneGap * 2 + laneHeight)

        // scenes lane
        if let tl = timeline {
            let scenes = tl.scenes.sorted { $0.at < $1.at }
            for (i, sc) in scenes.enumerated() {
                let end = i + 1 < scenes.count ? scenes[i + 1].at : duration
                let r = NSRect(x: x(sc.at), y: laneGap,
                               width: max(2, x(end) - x(sc.at)), height: laneHeight)
                colour(for: sc.layout).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 0),
                             xRadius: 4, yRadius: 4).fill()
                draw(sc.layout, in: r)
            }

            // zoom lane
            for z in tl.zooms {
                let r = NSRect(x: x(z.start), y: laneGap * 2 + laneHeight,
                               width: max(2, x(z.end) - x(z.start)), height: laneHeight)
                NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.24, alpha: 0.85).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 0),
                             xRadius: 4, yRadius: 4).fill()
                draw(String(format: "%.1fx", z.level), in: r)
            }
        }

        // playhead
        NSColor.white.setStroke()
        let ph = NSBezierPath()
        ph.move(to: NSPoint(x: x(playhead), y: 0))
        ph.line(to: NSPoint(x: x(playhead), y: bounds.height))
        ph.lineWidth = 2
        ph.stroke()
    }

    private func colour(for layout: String) -> NSColor {
        switch layout {
        case "talkingHead": return NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.85, alpha: 0.85)
        case "demo":        return NSColor(calibratedRed: 0.35, green: 0.65, blue: 0.45, alpha: 0.85)
        case "sideBySide":  return NSColor(calibratedRed: 0.60, green: 0.45, blue: 0.80, alpha: 0.85)
        default:            return NSColor(calibratedWhite: 0.45, alpha: 0.85)
        }
    }

    private func drawLabel(_ s: String, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
        ]
        s.draw(at: NSPoint(x: 8, y: y + 7), withAttributes: attrs)
    }

    private func draw(_ s: String, in r: NSRect) {
        guard r.width > 34 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        s.draw(at: NSPoint(x: r.minX + 6, y: r.minY + 6), withAttributes: attrs)
    }

    public override func mouseDown(with event: NSEvent) { seek(event) }
    public override func mouseDragged(with event: NSEvent) { seek(event) }

    private func seek(_ event: NSEvent) {
        guard duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let track = bounds.width - labelInset - 8
        let f = Double((p.x - labelInset) / max(track, 1))
        onSeek?(min(max(f, 0), 1) * duration)
    }
}
