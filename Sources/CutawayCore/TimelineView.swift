import AppKit
import AVFoundation

/// Ruler, waveform, then scene, zoom, speed and snippet lanes, with the playhead over all of
/// them. Drawn rather than built from subviews because the blocks change on
/// every edit.
public final class TimelineView: ThemedView {

    public var duration: Double = 0 { didSet { needsDisplay = true } }
    public var timeline: Timeline? { didSet { needsDisplay = true } }
    public var playhead: Double = 0 { didSet { needsDisplay = true } }
    /// The loops to post, drawn on their own lane under the cut list.
    public var snippets: [Snippet] = [] { didSet { needsDisplay = true } }
    public var selectedSnippet: Int? { didSet { needsDisplay = true } }
    public var onAddSnippet: ((Double) -> Void)?
    /// Same edges as a zoom: -1 left, 1 right, 0 the whole block.
    public var onMoveSnippet: ((_ index: Int, _ edge: Int, _ t: Double) -> Void)?
    public var onDeleteSnippet: ((Int) -> Void)?
    public var onSelectSnippet: ((Int) -> Void)?
    public var onSeek: ((Double) -> Void)?
    public var onMoveScene: ((Int, Double) -> Void)?
    public var onAddScene: ((Double) -> Void)?
    public var onTrim: ((_ isStart: Bool, _ t: Double) -> Void)?
    /// `edge` is -1 for the left handle, 1 for the right, 0 for the whole block.
    public var onMoveZoom: ((_ index: Int, _ edge: Int, _ t: Double) -> Void)?
    public var onAddZoom: ((Double) -> Void)?
    public var onDeleteZoom: ((Int) -> Void)?
    public var onNudgeZoomLevel: ((Double) -> Void)?
    /// The speed lane: set how fast one span runs, or split it in two.
    public var onSpanSpeed: ((Int, Double) -> Void)?
    public var onSplitSpan: ((Double) -> Void)?
    public var onRemoveSpan: ((Int) -> Void)?
    /// Bracket a drag, so it can be undone as one edit.
    public var onGestureBegan: (() -> Void)?
    public var onGestureEnded: (() -> Void)?

    private var dragging: Int?
    private var draggingTrim: Bool?
    private var draggingZoom: (index: Int, edge: Int)?
    private var draggingSnippet: (index: Int, edge: Int)?
    private var snippetGrabOffset: Double = 0
    private var zoomGrabOffset: Double = 0

    private var peaks: [Float] = []
    private var waveOffset: Double = 0
    private var waveDuration: Double = 0

    private let gutter: CGFloat = 56
    private let rulerHeight: CGFloat = 26
    private let waveTop: CGFloat = 32
    private let waveHeight: CGFloat = 62
    private let laneHeight: CGFloat = 22
    private var sceneY: CGFloat { waveTop + waveHeight + 10 }
    private var zoomY: CGFloat { sceneY + laneHeight + 6 }
    private var speedY: CGFloat { zoomY + laneHeight + 6 }
    private var snippetY: CGFloat { speedY + laneHeight + 6 }
    public static let preferredHeight: CGFloat = 32 + 62 + 10 + 22 + 6 + 22 + 6 + 22 + 6 + 22 + 10

    public override var acceptsFirstResponder: Bool { true }

    /// Keys the window wants first: play, step, and so on.
    public var onKey: ((NSEvent) -> Bool)?

    public override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        switch event.keyCode {
        case 126: onNudgeZoomLevel?(0.1)
        case 125: onNudgeZoomLevel?(-0.1)
        default: super.keyDown(with: event)
        }
    }

    private var trackWidth: CGFloat { max(bounds.width - gutter - 12, 1) }

    private func trackX(_ t: Double) -> CGFloat {
        gutter + trackWidth * CGFloat(min(max(t / max(duration, 0.001), 0), 1))
    }

    private func time(at p: NSPoint) -> Double {
        min(max(Double((p.x - gutter) / trackWidth), 0), 1) * duration
    }

    // MARK: drawing

    public override func draw(_ dirty: NSRect) {
        guard duration > 0 else { return }
        drawRuler()
        drawWaveform()
        drawCuts()
        drawLanes()
        drawTrim()
        drawPlayhead()
    }

    private func text(_ s: String, at p: NSPoint, _ style: Theme.Text, _ color: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [.font: style.font, .foregroundColor: color])
    }

    private func drawRuler() {
        // Pick a label spacing that keeps numbers about 60pt apart at any zoom.
        let pps = trackWidth / CGFloat(duration)
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let major = steps.first { CGFloat($0) * pps >= 60 } ?? 600
        let minor = major / 5

        Theme.divider.setFill()
        var t = 0.0
        while t <= duration + 0.0001 {
            let x = trackX(t).rounded() + 0.5
            let isMajor = abs(t.remainder(dividingBy: major)) < minor / 2
            NSRect(x: x, y: rulerHeight - (isMajor ? 9 : 5), width: 1, height: isMajor ? 9 : 5).fill()
            // Labels under the playhead tab would be unreadable, so they give way.
            if isMajor && abs(x - trackX(playhead)) > 26 {
                text(formatRuler(t), at: NSPoint(x: x + 3, y: 2), .caption, Theme.textTertiary)
            }
            t += minor
        }
        Theme.divider.setFill()
        NSRect(x: gutter, y: rulerHeight, width: trackWidth, height: 1).fill()
    }

    private func formatRuler(_ t: Double) -> String {
        if duration >= 60 {
            let s = Int(t.rounded())
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return t.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(t)) : String(format: "%.1f", t)
    }

    /// Mirrored, smoothed envelope. Averaging neighbours first is what turns a
    /// spiky peak list into the soft shape in the reference.
    private func drawWaveform() {
        text("Audio", at: NSPoint(x: 0, y: waveTop + waveHeight / 2 - 8), .caption, Theme.textTertiary)
        let mid = waveTop + waveHeight / 2

        guard !peaks.isEmpty, waveDuration > 0 else {
            Theme.waveform.setFill()
            NSRect(x: gutter, y: mid - 0.5, width: trackWidth, height: 1).fill()
            return
        }

        let columns = max(Int(trackWidth / 3), 2)
        var heights = [CGFloat](repeating: 0, count: columns)
        for c in 0..<columns {
            let t = duration * Double(c) / Double(columns - 1)
            let local = (t - waveOffset) / waveDuration
            guard local >= 0, local <= 1 else { continue }
            let i = min(Int(local * Double(peaks.count - 1)), peaks.count - 1)
            heights[c] = CGFloat(peaks[i])
        }
        let smoothed = heights.indices.map { i -> CGFloat in
            let lo = max(0, i - 3), hi = min(heights.count - 1, i + 3)
            return heights[lo...hi].reduce(0, +) / CGFloat(hi - lo + 1)
        }

        let path = NSBezierPath()
        let half = waveHeight / 2 - 2
        func px(_ c: Int) -> CGFloat { gutter + trackWidth * CGFloat(c) / CGFloat(columns - 1) }
        path.move(to: NSPoint(x: px(0), y: mid))
        for c in 0..<columns { path.line(to: NSPoint(x: px(c), y: mid - max(1, smoothed[c] * half))) }
        for c in stride(from: columns - 1, through: 0, by: -1) {
            path.line(to: NSPoint(x: px(c), y: mid + max(1, smoothed[c] * half)))
        }
        path.close()
        Theme.waveform.setFill()
        path.fill()

        // The column around the playhead is lit in the accent, as in the reference.
        let x = trackX(playhead)
        let column = NSRect(x: x - 9, y: waveTop, width: 18, height: waveHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: column).addClip()
        Theme.accent.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCuts() {
        guard let tl = timeline, !tl.timeMap.isIdentity else { return }
        let top = rulerHeight + 1, height = zoomY + laneHeight - top
        var prev = 0.0
        for s in tl.timeMap.segments {
            if s.sourceStart > prev {
                Theme.canvas.withAlphaComponent(0.7).setFill()
                NSRect(x: trackX(prev), y: top, width: max(1, trackX(s.sourceStart) - trackX(prev)),
                       height: height).fill(using: .sourceOver)
            }
            if s.speed > 1.01 {
                Theme.accent.withAlphaComponent(0.14).setFill()
                NSRect(x: trackX(s.sourceStart), y: top,
                       width: max(1, trackX(s.sourceEnd) - trackX(s.sourceStart)),
                       height: height).fill(using: .sourceOver)
            }
            prev = max(prev, s.sourceEnd)
        }
        if prev < duration {
            Theme.canvas.withAlphaComponent(0.7).setFill()
            NSRect(x: trackX(prev), y: top, width: max(1, trackX(duration) - trackX(prev)),
                   height: height).fill(using: .sourceOver)
        }
    }

    /// The cut list: what survives, and how fast each piece runs.
    private func drawSpans(_ tl: Timeline) {
        for (i, s) in tl.timeMap.segments.enumerated() {
            let r = NSRect(x: trackX(s.sourceStart), y: speedY,
                           width: max(2, trackX(s.sourceEnd) - trackX(s.sourceStart)),
                           height: laneHeight).insetBy(dx: 1, dy: 0)
            let fast = s.speed > 1.01
            let live = playhead >= s.sourceStart && playhead <= s.sourceEnd
            let fill = fast ? Theme.accent.withAlphaComponent(live ? 0.32 : 0.2)
                            : (live ? Theme.fillSelected : Theme.fill)
            fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: Theme.radiusControl,
                         yRadius: Theme.radiusControl).fill()
            if r.width > 34 {
                text(s.speed == 1 ? "1×" : "\(s.speed.clean)×",
                     at: NSPoint(x: r.minX + 7, y: r.minY + 3), .caption,
                     fast ? Theme.textPrimary : Theme.textSecondary)
            }
            _ = i
        }
    }

    private func drawLanes() {
        text("Scenes", at: NSPoint(x: 0, y: sceneY + 3), .caption, Theme.textTertiary)
        text("Zoom", at: NSPoint(x: 0, y: zoomY + 3), .caption, Theme.textTertiary)
        text("Speed", at: NSPoint(x: 0, y: speedY + 3), .caption, Theme.textTertiary)
        text("Snippets", at: NSPoint(x: 0, y: snippetY + 3), .caption, Theme.textTertiary)
        guard let tl = timeline else { return }
        drawSpans(tl)
        drawSnippets()

        let scenes = tl.scenes.sorted { $0.at < $1.at }
        for (i, sc) in scenes.enumerated() {
            let end = i + 1 < scenes.count ? scenes[i + 1].at : duration
            let r = NSRect(x: trackX(sc.at), y: sceneY,
                           width: max(2, trackX(end) - trackX(sc.at)), height: laneHeight)
                .insetBy(dx: 1, dy: 0)
            let current = playhead >= sc.at && playhead < end
            (current ? Theme.fillSelected : Theme.fill).setFill()
            NSBezierPath(roundedRect: r, xRadius: Theme.radiusControl, yRadius: Theme.radiusControl).fill()
            if r.width > 40 {
                text(readable(sc.layout), at: NSPoint(x: r.minX + 8, y: r.minY + 3), .caption,
                     current ? Theme.textPrimary : Theme.textSecondary)
            }
            if i > 0 {
                Theme.textTertiary.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX - 1.5, y: r.minY + 4, width: 3,
                                                 height: r.height - 8), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }

        for (i, z) in tl.zooms.enumerated() {
            let r = NSRect(x: trackX(z.start), y: zoomY,
                           width: max(2, trackX(z.end) - trackX(z.start)), height: laneHeight)
                .insetBy(dx: 1, dy: 0)
            let active = draggingZoom?.index == i || (playhead >= z.start && playhead <= z.end)
            Theme.accent.withAlphaComponent(active ? 0.3 : 0.16).setFill()
            NSBezierPath(roundedRect: r, xRadius: Theme.radiusControl, yRadius: Theme.radiusControl).fill()
            if r.width > 14 {
                Theme.accent.setFill()
                NSRect(x: r.minX + 3, y: r.minY + 6, width: 2, height: r.height - 12).fill()
                NSRect(x: r.maxX - 5, y: r.minY + 6, width: 2, height: r.height - 12).fill()
            }
            if r.width > 44 {
                text(String(format: "%.1f×", z.level), at: NSPoint(x: r.minX + 10, y: r.minY + 3),
                     .caption, Theme.textPrimary)
            }
        }
    }

    private func drawSnippets() {
        for (i, s) in snippets.enumerated() {
            let r = NSRect(x: trackX(s.start), y: snippetY,
                           width: max(2, trackX(s.end) - trackX(s.start)), height: laneHeight)
                .insetBy(dx: 1, dy: 0)
            let chosen = selectedSnippet == i || draggingSnippet?.index == i
            let path = NSBezierPath(roundedRect: r, xRadius: Theme.radiusControl,
                                    yRadius: Theme.radiusControl)
            (chosen ? Theme.fillSelected : Theme.fill).setFill()
            path.fill()
            if chosen {
                path.lineWidth = Theme.borderSelected
                Theme.accentBorder.setStroke()
                path.stroke()
            }
            if r.width > 14 {
                Theme.textTertiary.setFill()
                NSRect(x: r.minX + 3, y: r.minY + 6, width: 2, height: r.height - 12).fill()
                NSRect(x: r.maxX - 5, y: r.minY + 6, width: 2, height: r.height - 12).fill()
            }
            if r.width > 50 {
                let label = String(format: "%@  %.1fs", s.name, s.duration) as NSString
                label.draw(with: NSRect(x: r.minX + 10, y: r.minY + 3, width: r.width - 18, height: 16),
                           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                           attributes: [.font: Theme.Text.caption.font,
                                        .foregroundColor: chosen ? Theme.textPrimary : Theme.textSecondary])
            }
        }
    }

    private func readable(_ layout: String) -> String {
        switch layout {
        case "talkingHead": return "Talking head"
        case "screenOnly": return "Screen"
        case "sideBySide": return "Side by side"
        case "demo": return "Demo"
        default: return layout
        }
    }

    private func drawTrim() {
        guard let tl = timeline else { return }
        let lo = tl.trimStart, hi = min(tl.trimEnd, duration)
        let top = rulerHeight + 1, height = bounds.height - top
        Theme.canvas.withAlphaComponent(0.65).setFill()
        if lo > 0 {
            NSRect(x: gutter, y: top, width: trackX(lo) - gutter, height: height).fill(using: .sourceOver)
        }
        if hi < duration {
            NSRect(x: trackX(hi), y: top, width: trackX(duration) - trackX(hi), height: height)
                .fill(using: .sourceOver)
        }
        guard lo > 0 || hi < duration else { return }
        Theme.textSecondary.setFill()
        for (t, isStart) in [(lo, true), (hi, false)] {
            let x = trackX(t) + (isStart ? 0 : -4)
            NSBezierPath(roundedRect: NSRect(x: x, y: top + 2, width: 4, height: height - 4),
                         xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawPlayhead() {
        let x = trackX(playhead).rounded()
        Theme.accent.setFill()
        NSRect(x: x - 0.75, y: rulerHeight - 4, width: 1.5, height: bounds.height - rulerHeight + 4).fill()

        let label = duration >= 60
            ? String(format: "%d:%02d", Int(playhead) / 60, Int(playhead) % 60)
            : String(Int(playhead))
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Text.caption.font,
                                                    .foregroundColor: Theme.onAccent]
        let s = (label as NSString).size(withAttributes: attrs)
        let tab = NSRect(x: x - max(s.width + 8, 16) / 2, y: 3, width: max(s.width + 8, 16), height: 17)
        NSBezierPath(roundedRect: tab, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: NSPoint(x: tab.midX - s.width / 2, y: tab.midY - s.height / 2),
                                 withAttributes: attrs)
    }

    // MARK: interaction

    enum Lane { case ruler, wave, scene, zoom, speed, snippet }

    /// Where a moment sits on a lane, in this view's coordinates.
    func point(at t: Double, lane: Lane) -> NSPoint {
        let y: CGFloat
        switch lane {
        case .ruler: y = rulerHeight / 2
        case .wave: y = waveTop + waveHeight / 2
        case .scene: y = sceneY + laneHeight / 2
        case .zoom: y = zoomY + laneHeight / 2
        case .speed: y = speedY + laneHeight / 2
        case .snippet: y = snippetY + laneHeight / 2
        }
        return NSPoint(x: trackX(t), y: y)
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        // Option-click deletes, and it wins over grabbing a handle underneath.
        if event.modifierFlags.contains(.option), let hit = zoomHit(p) {
            onDeleteZoom?(hit.index)
            return
        }
        if isInSnippetLane(p) {
            if let hit = snippetHit(p) {
                if event.modifierFlags.contains(.option) {
                    onDeleteSnippet?(hit.index)
                    return
                }
                onSelectSnippet?(hit.index)
                onGestureBegan?()
                draggingSnippet = hit
                if hit.edge == 0 { snippetGrabOffset = time(at: p) - snippets[hit.index].start }
                return
            }
            if event.clickCount == 2 { onAddSnippet?(time(at: p)); return }
            onSeek?(time(at: p))
            return
        }
        if let isStart = trimHandle(near: p) {
            draggingTrim = isStart
            onGestureBegan?()
            return
        }
        if let i = sceneHandle(near: p) {
            dragging = i
            onGestureBegan?()
            return
        }

        if let hit = zoomHit(p) {
            onGestureBegan?()
            draggingZoom = hit
            if hit.edge == 0, let z = timeline?.zooms[hit.index] {
                zoomGrabOffset = time(at: p) - z.start
            }
            return
        }
        if isInSpeedLane(p) {
            if event.clickCount == 2 { onSplitSpan?(time(at: p)); return }
            if event.modifierFlags.contains(.option), let i = spanIndex(at: p) {
                onRemoveSpan?(i)
                return
            }
            onSeek?(time(at: p))
            return
        }
        if event.clickCount == 2, isInZoomLane(p) { onAddZoom?(time(at: p)); return }
        if event.clickCount == 2, isInSceneLane(p) { onAddScene?(time(at: p)); return }
        dragging = nil
        onSeek?(time(at: p))
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let isStart = draggingTrim { onTrim?(isStart, time(at: p)); return }
        if let z = draggingZoom {
            onMoveZoom?(z.index, z.edge, z.edge == 0 ? time(at: p) - zoomGrabOffset : time(at: p))
            return
        }
        if let s = draggingSnippet {
            onMoveSnippet?(s.index, s.edge, s.edge == 0 ? time(at: p) - snippetGrabOffset : time(at: p))
            return
        }
        if let i = dragging { onMoveScene?(i, time(at: p)); return }
        onSeek?(time(at: p))
    }

    public override func mouseUp(with event: NSEvent) {
        let wasEditing = dragging != nil || draggingTrim != nil || draggingZoom != nil
            || draggingSnippet != nil
        dragging = nil
        draggingTrim = nil
        draggingZoom = nil
        draggingSnippet = nil
        if wasEditing { onGestureEnded?() }
    }

    private func trimHandle(near p: NSPoint) -> Bool? {
        guard let tl = timeline, duration > 0, p.y > rulerHeight else { return nil }
        if abs(trackX(tl.trimStart) - p.x) < 8 { return true }
        if abs(trackX(min(tl.trimEnd, duration)) - p.x) < 8 { return false }
        return nil
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard let tl = timeline, duration > 0 else { return }
        for (i, sc) in tl.scenes.sorted(by: { $0.at < $1.at }).enumerated() where i > 0 {
            addCursorRect(NSRect(x: trackX(sc.at) - 5, y: sceneY, width: 10, height: laneHeight),
                          cursor: .resizeLeftRight)
        }
        for t in [tl.trimStart, min(tl.trimEnd, duration)] {
            addCursorRect(NSRect(x: trackX(t) - 6, y: rulerHeight, width: 12,
                                 height: bounds.height - rulerHeight), cursor: .resizeLeftRight)
        }
        for z in tl.zooms {
            for t in [z.start, z.end] {
                addCursorRect(NSRect(x: trackX(t) - 6, y: zoomY, width: 12, height: laneHeight),
                              cursor: .resizeLeftRight)
            }
            let a = trackX(z.start), b = trackX(z.end)
            if b - a > 18 {
                addCursorRect(NSRect(x: a + 7, y: zoomY, width: b - a - 14, height: laneHeight),
                              cursor: .openHand)
            }
        }
        for s in snippets {
            for t in [s.start, s.end] {
                addCursorRect(NSRect(x: trackX(t) - 6, y: snippetY, width: 12, height: laneHeight),
                              cursor: .resizeLeftRight)
            }
            let a = trackX(s.start), b = trackX(s.end)
            if b - a > 18 {
                addCursorRect(NSRect(x: a + 7, y: snippetY, width: b - a - 14, height: laneHeight),
                              cursor: .openHand)
            }
        }
    }

    private func isInZoomLane(_ p: NSPoint) -> Bool { p.y >= zoomY && p.y <= zoomY + laneHeight }
    private func isInSpeedLane(_ p: NSPoint) -> Bool { p.y >= speedY && p.y <= speedY + laneHeight }
    private func isInSnippetLane(_ p: NSPoint) -> Bool { p.y >= snippetY && p.y <= snippetY + laneHeight }

    private func snippetHit(_ p: NSPoint) -> (index: Int, edge: Int)? {
        for (i, s) in snippets.enumerated() {
            let a = trackX(s.start), b = trackX(s.end)
            if abs(a - p.x) < 7 { return (i, -1) }
            if abs(b - p.x) < 7 { return (i, 1) }
            if p.x > a && p.x < b { return (i, 0) }
        }
        return nil
    }

    private func spanIndex(at p: NSPoint) -> Int? {
        guard let tl = timeline else { return nil }
        let t = time(at: p)
        return tl.timeMap.segments.firstIndex { t >= $0.sourceStart && t <= $0.sourceEnd }
    }

    /// Right-click a span to set its speed, which is where people look for it.
    public override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard isInSpeedLane(p), let i = spanIndex(at: p) else {
            super.rightMouseDown(with: event)
            return
        }
        speedMenuIndex = i
        let menu = NSMenu()
        for speed in [1.0, 1.5, 2.0, 4.0, 8.0] {
            let item = NSMenuItem(title: "\(speed.clean)×", action: #selector(pickSpanSpeed(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = abs((timeline?.timeMap.segments[i].speed ?? 1) - speed) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let split = NSMenuItem(title: "Split here", action: #selector(splitSpan), keyEquivalent: "")
        split.target = self
        menu.addItem(split)
        let cut = NSMenuItem(title: "Remove this piece", action: #selector(removeSpan),
                             keyEquivalent: "")
        cut.target = self
        menu.addItem(cut)
        splitAt = time(at: p)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Hooks for the scripted check: the menu itself cannot be driven.
    func testSpanSpeed(index: Int, speed: Double) { onSpanSpeed?(index, speed) }
    func testRemoveSpan(index: Int) { onRemoveSpan?(index) }

    private var speedMenuIndex: Int?
    private var splitAt: Double = 0

    @objc private func pickSpanSpeed(_ item: NSMenuItem) {
        guard let i = speedMenuIndex, let speed = item.representedObject as? Double else { return }
        onSpanSpeed?(i, speed)
    }

    @objc private func splitSpan() { onSplitSpan?(splitAt) }

    @objc private func removeSpan() {
        guard let i = speedMenuIndex else { return }
        onRemoveSpan?(i)
    }
    private func isInSceneLane(_ p: NSPoint) -> Bool { p.y >= sceneY && p.y <= sceneY + laneHeight }

    private func zoomHit(_ p: NSPoint) -> (index: Int, edge: Int)? {
        guard let tl = timeline, isInZoomLane(p) else { return nil }
        for (i, z) in tl.zooms.enumerated() {
            let a = trackX(z.start), b = trackX(z.end)
            if abs(a - p.x) < 7 { return (i, -1) }
            if abs(b - p.x) < 7 { return (i, 1) }
            if p.x > a && p.x < b { return (i, 0) }
        }
        return nil
    }

    private func sceneHandle(near p: NSPoint) -> Int? {
        guard let tl = timeline, isInSceneLane(p) else { return nil }
        for (i, sc) in tl.scenes.sorted(by: { $0.at < $1.at }).enumerated() where i > 0 {
            if abs(trackX(sc.at) - p.x) < 7 { return i }
        }
        return nil
    }

    public func loadWaveform(from dir: URL, manifest: Manifest?) {
        peaks = []
        guard let track = Waveform.preferredTrack(in: dir, manifest: manifest) else {
            needsDisplay = true
            return
        }
        waveOffset = manifest?.mic?.offset ?? 0
        Task { [weak self] in
            let asset = AVURLAsset(url: track)
            let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            let p = await Waveform.peaks(from: track)
            await MainActor.run {
                self?.peaks = p
                self?.waveDuration = dur
                self?.needsDisplay = true
            }
        }
    }
}
