import AppKit
import AVFoundation

/// The timeline strip: scenes on one lane, zooms on another, playhead over
/// both. Clicking or dragging seeks. Deliberately drawn rather than built from
/// subviews, because the number of blocks changes on every edit.
public final class TimelineView: NSView {

    public var duration: Double = 0 { didSet { needsDisplay = true } }
    public var timeline: Timeline? { didSet { needsDisplay = true } }
    public var playhead: Double = 0 { didSet { needsDisplay = true } }
    public var onSeek: ((Double) -> Void)?
    /// Called when a scene marker is dragged, so the handover point can be
    /// moved without editing JSON.
    public var onMoveScene: ((Int, Double) -> Void)?
    public var onAddScene: ((Double) -> Void)?
    /// Dragging either end of the recording. `isStart` distinguishes them.
    public var onTrim: ((_ isStart: Bool, _ t: Double) -> Void)?
    /// Dragging a zoom block. `edge` is -1 for the left handle, 1 for the
    /// right, 0 for the whole block.
    public var onMoveZoom: ((_ index: Int, _ edge: Int, _ t: Double) -> Void)?
    public var onAddZoom: ((Double) -> Void)?
    public var onDeleteZoom: ((Int) -> Void)?
    public var onNudgeZoomLevel: ((Double) -> Void)?

    private var thumbnails: [(t: Double, image: NSImage)] = []
    private var thumbnailTask: Task<Void, Never>?
    private var dragging: Int?
    private var draggingTrim: Bool?
    /// Which zoom is being dragged, and by which edge.
    private var draggingZoom: (index: Int, edge: Int)?
    /// Where in the block the drag started, so moving a whole block does not
    /// snap its start to the pointer.
    private var zoomGrabOffset: Double = 0

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onNudgeZoomLevel?(0.1)    // up
        case 125: onNudgeZoomLevel?(-0.1)   // down
        default: super.keyDown(with: event)
        }
    }

    private let laneHeight: CGFloat = 26
    private let laneGap: CGFloat = 6
    private let labelInset: CGFloat = 54
    private let filmstripHeight: CGFloat = 34
    private let waveHeight: CGFloat = 22
    private var peaks: [Float] = []
    /// Where the audio starts relative to the screen recording.
    private var waveOffset: Double = 0
    private var waveDuration: Double = 0

    /// Top of the scene and zoom lanes, which moves when there is a waveform.
    private var lanesTop: CGFloat {
        filmstripHeight + (peaks.isEmpty ? 0 : waveHeight)
    }

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

        // Filmstrip along the top: the fastest way to find a moment.
        if !thumbnails.isEmpty {
            for (i, thumb) in thumbnails.enumerated() {
                let next = i + 1 < thumbnails.count ? thumbnails[i + 1].t : duration
                let r = NSRect(x: x(thumb.t), y: 0,
                               width: max(1, x(next) - x(thumb.t)),
                               height: filmstripHeight)
                thumb.image.draw(in: r, from: .zero, operation: .copy, fraction: 0.9)
            }
            NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
            NSRect(x: track.minX, y: filmstripHeight - 1,
                   width: track.width, height: 1).fill()
        }

        // Waveform under the filmstrip: speech shows up as clusters, which is
        // how you find the sentence you meant.
        if !peaks.isEmpty, waveDuration > 0 {
            let top = filmstripHeight
            NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
            NSRect(x: track.minX, y: top, width: track.width, height: waveHeight).fill()

            NSColor(calibratedRed: 0.40, green: 0.72, blue: 0.94, alpha: 0.9).setFill()
            let mid = top + waveHeight / 2
            for (i, v) in peaks.enumerated() {
                let t = waveOffset + waveDuration * Double(i) / Double(peaks.count)
                guard t >= 0, t <= duration else { continue }
                let h = max(1, CGFloat(v) * (waveHeight - 3))
                NSRect(x: x(t), y: mid - h / 2, width: 1, height: h).fill()
            }
            drawLabel("audio", y: top - 1)
        }

        drawLabel("scenes", y: lanesTop + laneGap)
        drawLabel("zoom", y: lanesTop + laneGap * 2 + laneHeight)

        // scenes lane
        if let tl = timeline {
            let scenes = tl.scenes.sorted { $0.at < $1.at }
            for (i, sc) in scenes.enumerated() {
                let end = i + 1 < scenes.count ? scenes[i + 1].at : duration
                let r = NSRect(x: x(sc.at), y: lanesTop + laneGap,
                               width: max(2, x(end) - x(sc.at)), height: laneHeight)
                colour(for: sc.layout).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 0),
                             xRadius: 4, yRadius: 4).fill()
                draw(sc.layout, in: r)

                // Drag handle, skipped on the opening scene because a video
                // has to start somewhere.
                if i > 0 {
                    NSColor.white.setFill()
                    NSRect(x: r.minX - 1, y: r.minY, width: 3, height: r.height).fill()
                }
            }

            // zoom lane
            for (i, z) in tl.zooms.enumerated() {
                let r = NSRect(x: x(z.start), y: lanesTop + laneGap * 2 + laneHeight,
                               width: max(2, x(z.end) - x(z.start)), height: laneHeight)
                let active = draggingZoom?.index == i
                NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.24,
                        alpha: active ? 1.0 : 0.85).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 0),
                             xRadius: 4, yRadius: 4).fill()

                // Edge grips, so it is obvious the ends can be dragged.
                if r.width > 14 {
                    NSColor(calibratedWhite: 1, alpha: 0.75).setFill()
                    NSRect(x: r.minX + 2, y: r.minY + 5, width: 2, height: r.height - 10).fill()
                    NSRect(x: r.maxX - 4, y: r.minY + 5, width: 2, height: r.height - 10).fill()
                }
                draw(String(format: "%.1fx", z.level), in: r)
            }
        }

        // Trimmed material, dimmed rather than hidden so you can still see
        // what you are cutting away and drag it back.
        if let tl = timeline {
            let lo = tl.trimStart
            let hi = min(tl.trimEnd, duration)
            NSColor(calibratedWhite: 0.03, alpha: 0.72).setFill()
            if lo > 0 {
                NSRect(x: track.minX, y: 0, width: x(lo) - track.minX,
                       height: bounds.height).fill()
            }
            if hi < duration {
                NSRect(x: x(hi), y: 0, width: track.maxX - x(hi),
                       height: bounds.height).fill()
            }

            NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.30, alpha: 1).setFill()
            for (t, isStart) in [(lo, true), (hi, false)] {
                let hx = isStart ? x(t) : x(t) - 4
                NSRect(x: hx, y: 0, width: 4, height: bounds.height).fill()
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

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let isStart = trimHandle(near: p) { draggingTrim = isStart; return }
        if let i = sceneHandle(near: p) { dragging = i; return }

        window?.makeFirstResponder(self)
        if let hit = zoomHit(p) {
            // Alt-click removes a zoom; it is the one destructive action here
            // so it needs a modifier rather than a plain click.
            if event.modifierFlags.contains(.option) {
                onDeleteZoom?(hit.index)
                return
            }
            draggingZoom = hit
            if hit.edge == 0, let z = timeline?.zooms[hit.index] {
                zoomGrabOffset = time(at: p) - z.start
            }
            return
        }
        if event.clickCount == 2, isInZoomLane(p) {
            onAddZoom?(time(at: p))
            return
        }
        // Double-click on the scenes lane adds a handover there.
        if event.clickCount == 2, isInSceneLane(p) {
            onAddScene?(time(at: p))
            return
        }
        dragging = nil
        seek(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let isStart = draggingTrim {
            onTrim?(isStart, time(at: p))
            return
        }
        if let z = draggingZoom {
            onMoveZoom?(z.index, z.edge,
                        z.edge == 0 ? time(at: p) - zoomGrabOffset : time(at: p))
            return
        }
        if let i = dragging {
            onMoveScene?(i, time(at: p))
            return
        }
        seek(event)
    }

    public override func mouseUp(with event: NSEvent) {
        dragging = nil
        draggingTrim = nil
        draggingZoom = nil
    }

    /// Which end of the recording is under the pointer, if either. Checked
    /// before scene markers because the handles sit at the extremes where a
    /// scene marker never does.
    private func trimHandle(near p: NSPoint) -> Bool? {
        guard let tl = timeline, duration > 0 else { return nil }
        if abs(trackX(tl.trimStart) - p.x) < 8 { return true }
        if abs(trackX(min(tl.trimEnd, duration)) - p.x) < 8 { return false }
        return nil
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard let tl = timeline, duration > 0 else { return }
        let scenes = tl.scenes.sorted { $0.at < $1.at }
        for (i, sc) in scenes.enumerated() where i > 0 {
            let x = trackX(sc.at)
            addCursorRect(NSRect(x: x - 5, y: lanesTop + laneGap,
                                 width: 10, height: laneHeight),
                          cursor: .resizeLeftRight)
        }
        for t in [tl.trimStart, min(tl.trimEnd, duration)] {
            addCursorRect(NSRect(x: trackX(t) - 6, y: 0, width: 12, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
        for z in tl.zooms {
            for t in [z.start, z.end] {
                addCursorRect(NSRect(x: trackX(t) - 6, y: zoomLaneY,
                                     width: 12, height: laneHeight),
                              cursor: .resizeLeftRight)
            }
            let a = trackX(z.start), b = trackX(z.end)
            if b - a > 18 {
                addCursorRect(NSRect(x: a + 7, y: zoomLaneY,
                                     width: b - a - 14, height: laneHeight),
                              cursor: .openHand)
            }
        }
    }

    private var zoomLaneY: CGFloat { lanesTop + laneGap * 2 + laneHeight }

    private func isInZoomLane(_ p: NSPoint) -> Bool {
        p.y >= zoomLaneY && p.y <= zoomLaneY + laneHeight
    }

    /// Which zoom block is under the pointer, and whether the pointer is on an
    /// edge. Edges win over the body so a narrow block can still be resized.
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

    private func isInSceneLane(_ p: NSPoint) -> Bool {
        p.y >= lanesTop + laneGap && p.y <= lanesTop + laneGap + laneHeight
    }

    private func trackX(_ t: Double) -> CGFloat {
        let track = bounds.width - labelInset - 8
        return labelInset + track * CGFloat(min(max(t / max(duration, 0.001), 0), 1))
    }

    private func time(at p: NSPoint) -> Double {
        let track = bounds.width - labelInset - 8
        return min(max(Double((p.x - labelInset) / max(track, 1)), 0), 1) * duration
    }

    private func sceneHandle(near p: NSPoint) -> Int? {
        guard let tl = timeline, isInSceneLane(p) else { return nil }
        let scenes = tl.scenes.sorted { $0.at < $1.at }
        for (i, sc) in scenes.enumerated() where i > 0 {
            if abs(trackX(sc.at) - p.x) < 7 { return i }
        }
        return nil
    }

    /// Decodes a handful of frames in the background. Cheap enough to redo on
    /// load, and it makes finding a moment far quicker than scrubbing.
    /// Decodes the audio envelope in the background. Never blocks first paint.
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

    public func loadThumbnails(from url: URL, count: Int = 12) {
        thumbnailTask?.cancel()
        thumbnails = []
        let total = duration
        guard total > 0 else { return }
        thumbnailTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 220, height: 140)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
            for i in 0..<count {
                if Task.isCancelled { return }
                let t = total * Double(i) / Double(count)
                guard let (img, _) = try? await gen.image(
                    at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
                let image = NSImage(cgImage: img,
                                    size: NSSize(width: img.width, height: img.height))
                await MainActor.run {
                    self?.thumbnails.append((t, image))
                    self?.needsDisplay = true
                }
            }
        }
    }

    private func seek(_ event: NSEvent) {
        guard duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let track = bounds.width - labelInset - 8
        let f = Double((p.x - labelInset) / max(track, 1))
        onSeek?(min(max(f, 0), 1) * duration)
    }
}
