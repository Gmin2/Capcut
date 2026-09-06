import Foundation
import CoreGraphics
import simd

/// A zoom keyframe. Times are in *source* time, never output time, so cutting a
/// segment later does not require rewriting every keyframe.
public struct Zoom: Codable {
    public var start: Double
    public var end: Double
    public var inDuration: Double = 0.45
    public var outDuration: Double = 0.6
    public var level: Double = 2.0
    /// Normalised 0...1 fallback focus, used when not following the cursor.
    public var anchor: [Double] = [0.5, 0.5]
    public var follow: Follow? = Follow()

    public struct Follow: Codable {
        public var mode: String = "cursor"
        /// One-pole filter coefficient per frame at 60fps. Lower is lazier.
        public var damping: Double = 0.06
        /// Source pixels of slack before the camera reacts at all. Without this
        /// the frame breathes constantly while the pointer hovers in place.
        public var deadzone: Double = 60
        public init() {}
    }

    public init(start: Double, end: Double, level: Double = 2.0) {
        self.start = start
        self.end = end
        self.level = level
    }
}

/// CSS-style cubic bezier easing. Linear zooms read as mechanical and
/// easeInOut visually overshoots, so the curve is worth having properly.
public struct CubicBezier {
    let x1, y1, x2, y2: Double
    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2)
    }

    private func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let mt = 1 - t
        return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t
    }

    public func solve(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        // Newton, falling back to bisection if the curve is unfriendly.
        var t = x
        for _ in 0..<8 {
            let cx = curve(t, x1, x2) - x
            if abs(cx) < 1e-6 { return curve(t, y1, y2) }
            let mt = 1 - t
            let d = 3 * mt * mt * x1 + 6 * mt * t * (x2 - x1) + 3 * t * t * (1 - x2)
            if abs(d) < 1e-6 { break }
            t -= cx / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<20 {
            let cx = curve(t, x1, x2)
            if abs(cx - x) < 1e-6 { break }
            if cx < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return curve(t, y1, y2)
    }

    public static let zoomIn  = CubicBezier(0.32, 0.72, 0.0, 1.0)
    public static let zoomOut = CubicBezier(0.4, 0.0, 0.35, 1.0)
}

/// Everything time-varying about a project, resolved into a form that makes
/// `crop(at:)` a pure lookup.
/// Everything needed to draw one output frame.
public struct FrameDescription {
    public var background: BackgroundParams
    public var screen: LayerParams?
    public var webcam: LayerParams?
    public var cursor: CursorParams?
    /// Text to show, and where. The caller turns this into a texture, because
    /// drawing it is CPU work that should only happen when the text changes.
    public var keycast: (text: String, opacity: Double, rect: CGRect)?
    public var callout: (id: String, opacity: Double, rect: CGRect, callout: Callout)?
}

public final class Timeline: @unchecked Sendable {
    public let zooms: [Zoom]
    public let sourceSize: CGSize
    public var scenes: [Scene] = [Scene(at: 0, layout: "screenOnly")]
    public var style: Style = .default
    public var cursorStyle = CursorStyle()
    /// Per-export layout table. Vertical and square output reframe everything,
    /// so the scene names stay the same and only their geometry changes.
    public var layouts: [String: Layout] = Layout.named
    public var keycastStyle = KeycastStyle()
    public var callouts: [Callout] = []
    public var calloutTheme = CalloutTheme()
    public var deviceFrame: DeviceFrame = .none
    public var masks: [Mask] = []
    /// 0 disables motion blur. 1 is roughly a 180-degree shutter, which is what
    /// film looks like; above that reads as smeary.
    public var motionBlur: Double = 0.85
    private var keyChips: [KeyChip] = []

    public func setKeys(_ keys: [EventRecorder.Key]) {
        keyChips = KeycastBuilder.chips(from: keys, style: keycastStyle)
    }
    public var clicks: [(t: Double, p: CGPoint)] = []
    /// Cuts and speed ramps. Effects stay in source time; this maps to output.
    public var timeMap = TimeMap(segments: [], sourceDuration: 0)

    /// Lightly smoothed pointer path, distinct from the camera's heavily damped
    /// focus track: the camera should lag, the pointer should not.
    private var drawTimes: [Double] = []
    private var drawPoints: [CGPoint] = []

    /// Cursor smoothing is stateful, so it is integrated once here rather than
    /// recomputed per frame. Keeps evaluation pure and makes scrubbing exact:
    /// seeking backwards gives the identical frame you saw going forwards.
    private var focusTimes: [Double] = []
    private var focusPoints: [CGPoint] = []

    public init(zooms: [Zoom], sourceSize: CGSize, cursor: [(t: Double, p: CGPoint)]) {
        self.zooms = zooms
        self.sourceSize = sourceSize
        guard !cursor.isEmpty else { return }

        let damping = zooms.first?.follow?.damping ?? 0.06
        let deadzone = zooms.first?.follow?.deadzone ?? 60
        var focus = cursor[0].p
        var target = cursor[0].p
        focusTimes.reserveCapacity(cursor.count)
        focusPoints.reserveCapacity(cursor.count)

        for s in cursor {
            if hypot(s.p.x - target.x, s.p.y - target.y) > deadzone { target = s.p }
            focus.x += (target.x - focus.x) * damping
            focus.y += (target.y - focus.y) * damping
            focusTimes.append(s.t)
            focusPoints.append(focus)
        }

        var draw = cursor[0].p
        let a = 1.0 - min(max(0.0, 0.45), 0.95)
        drawTimes.reserveCapacity(cursor.count)
        drawPoints.reserveCapacity(cursor.count)
        for s in cursor {
            draw.x += (s.p.x - draw.x) * a
            draw.y += (s.p.y - draw.y) * a
            drawTimes.append(s.t)
            drawPoints.append(draw)
        }
    }

    private func sample(_ times: [Double], _ points: [CGPoint], _ t: Double) -> CGPoint? {
        guard !times.isEmpty else { return nil }
        if t <= times[0] { return points[0] }
        if t >= times[times.count - 1] { return points[points.count - 1] }
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        let span = times[hi] - times[lo]
        let f = span > 0 ? (t - times[lo]) / span : 0
        return CGPoint(x: points[lo].x + (points[hi].x - points[lo].x) * f,
                       y: points[lo].y + (points[hi].y - points[lo].y) * f)
    }

    /// Maps the recorded pointer into output space through whatever crop and
    /// placement the screen layer currently has, so it stays glued to the
    /// pixel it was actually over even mid-zoom.
    public func cursorParams(at t: Double, screen: LayerParams?,
                             outputSize: CGSize) -> CursorParams? {
        guard cursorStyle.visible, let screen, screen.opacity > 0.01,
              let sp = sample(drawTimes, drawPoints, t) else { return nil }

        let crop = CGRect(x: Double(screen.src.x), y: Double(screen.src.y),
                          width: Double(screen.src.z), height: Double(screen.src.w))
        let dst = CGRect(x: Double(screen.dst.x), y: Double(screen.dst.y),
                         width: Double(screen.dst.z), height: Double(screen.dst.w))
        guard crop.width > 0, crop.height > 0 else { return nil }

        let local = CGPoint(x: (sp.x - crop.minX) / crop.width,
                            y: (sp.y - crop.minY) / crop.height)
        // Off the visible crop: no pointer rather than one pinned to the edge.
        guard local.x >= -0.05, local.x <= 1.05, local.y >= -0.05, local.y <= 1.05
        else { return nil }
        let out = CGPoint(x: dst.minX + local.x * dst.width,
                          y: dst.minY + local.y * dst.height)

        // Sized from a fixed base height, not from the texture's resolution,
        // so bumping the texture never changes how big the pointer looks.
        let h = CursorImage.baseHeight * cursorStyle.scale * (outputSize.height / 1080.0)
        let w = h * (CursorImage.size.width / CursorImage.size.height)
        let hot = CursorImage.hotSpotFraction

        var p = CursorParams()
        p.outputSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        p.rect = SIMD4(Float(out.x - hot.x * w), Float(out.y - hot.y * h),
                       Float(w), Float(h))
        p.opacity = Float(screen.opacity)

        if cursorStyle.clickRipple,
           let c = clicks.last(where: { t >= $0.t && t - $0.t <= cursorStyle.rippleDuration }) {
            let age = (t - c.t) / cursorStyle.rippleDuration
            let cl = CGPoint(x: (c.p.x - crop.minX) / crop.width,
                             y: (c.p.y - crop.minY) / crop.height)
            let co = CGPoint(x: dst.minX + cl.x * dst.width,
                             y: dst.minY + cl.y * dst.height)
            let eased = CubicBezier.zoomIn.solve(age)
            p.ripplePos = SIMD2(Float(co.x), Float(co.y))
            p.rippleRadius = Float(cursorStyle.rippleRadius
                                   * (outputSize.height / 1080.0) * (0.25 + eased))
            p.rippleAlpha = Float((1 - age) * Double(screen.opacity))
            p.rippleColor = Style.rgba(cursorStyle.rippleColor)
        }
        return p
    }

    func focus(at t: Double) -> CGPoint? {
        guard !focusTimes.isEmpty else { return nil }
        if t <= focusTimes[0] { return focusPoints[0] }
        if t >= focusTimes[focusTimes.count - 1] { return focusPoints[focusPoints.count - 1] }
        var lo = 0, hi = focusTimes.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if focusTimes[mid] <= t { lo = mid } else { hi = mid }
        }
        let span = focusTimes[hi] - focusTimes[lo]
        let f = span > 0 ? (t - focusTimes[lo]) / span : 0
        return CGPoint(x: focusPoints[lo].x + (focusPoints[hi].x - focusPoints[lo].x) * f,
                       y: focusPoints[lo].y + (focusPoints[hi].y - focusPoints[lo].y) * f)
    }

    /// Zoom level at a time. Interpolates log(level), not level: scale is
    /// perceived logarithmically, and a linear ramp visually overshoots.
    func level(at t: Double, zoom: Zoom) -> Double {
        let z = max(1.0, zoom.level)
        if t < zoom.start || t > zoom.end { return 1 }
        if t < zoom.start + zoom.inDuration {
            let p = CubicBezier.zoomIn.solve((t - zoom.start) / zoom.inDuration)
            return exp(log(1.0) * (1 - p) + log(z) * p)
        }
        if t > zoom.end - zoom.outDuration {
            let p = CubicBezier.zoomOut.solve((zoom.end - t) / zoom.outDuration)
            return exp(log(1.0) * (1 - p) + log(z) * p)
        }
        return z
    }

    /// Layout at a time, interpolating across a scene transition. Returns
    /// resolved layer parameters, not layout names, so the caller never has to
    /// know how scenes work.
    private func layout(at t: Double, screenSize: CGSize, webcamSize: CGSize?,
                        outputSize: CGSize) -> (screen: LayerParams?, webcam: LayerParams?) {
        let ordered = scenes.sorted { $0.at < $1.at }
        var currentIndex = 0
        for (i, s) in ordered.enumerated() where s.at <= t { currentIndex = i }
        let current = ordered[currentIndex]

        func resolve(_ name: String) -> (LayerParams?, LayerParams?) {
            let l = layouts[name] ?? Layout.named[name] ?? .screenOnly
            var placement = l.screen
            if deviceFrame != .none { placement?.frame = deviceFrame }
            let s = placement?.layerParams(sourceSize: screenSize, outputSize: outputSize)
            let w = webcamSize.flatMap { size in
                l.webcam?.layerParams(sourceSize: size, outputSize: outputSize)
            }
            return (s, w)
        }

        var (screen, webcam) = resolve(current.layout)

        // Blend in from the previous layout while the transition is running.
        let elapsed = t - current.at
        if currentIndex > 0, current.transition > 0, elapsed < current.transition {
            let (ps, pw) = resolve(ordered[currentIndex - 1].layout)
            let f = Float(CubicBezier.zoomIn.solve(elapsed / current.transition))
            screen = blend(ps, screen, f)
            webcam = blend(pw, webcam, f)
        }
        return (screen, webcam)
    }

    /// A layer appearing or disappearing scales from its own centre rather than
    /// popping, which is why the missing side is synthesised instead of nil.
    private func blend(_ a: LayerParams?, _ b: LayerParams?, _ f: Float) -> LayerParams? {
        switch (a, b) {
        case let (a?, b?): return mix(a, b, f)
        case let (a?, nil): return mix(a, Placement.hidden(like: a), f)
        case let (nil, b?): return mix(Placement.hidden(like: b), b, f)
        default: return nil
        }
    }

    public func frame(at t: Double, screenSize: CGSize, webcamSize: CGSize?,
                      outputSize: CGSize) -> FrameDescription {
        var (screen, webcam) = layout(at: t, screenSize: screenSize,
                                      webcamSize: webcamSize, outputSize: outputSize)
        if var s = screen {
            let c = crop(at: t)
            s.src = SIMD4(Float(c.origin.x), Float(c.origin.y),
                          Float(c.width), Float(c.height))
            applyMasks(to: &s, at: t)
            applyMotion(to: &s, at: t, crop: c)
            screen = s
        }
        var f = FrameDescription(background: style.backgroundParams(outputSize: outputSize,
                                                                   sourceSize: sourceSize),
                                 screen: screen, webcam: webcam,
                                 cursor: cursorParams(at: t, screen: screen,
                                                      outputSize: outputSize))
        if let k = KeycastRenderer.frame(chips: keyChips, at: t, style: keycastStyle,
                                         outputSize: outputSize) {
            f.keycast = (k.text, k.opacity, CGRect(origin: k.origin, size: k.size))
        }
        if let c = CalloutRenderer.resolve(callouts, at: t, theme: calloutTheme,
                                           outputSize: outputSize) {
            f.callout = (c.id, c.opacity, CGRect(origin: c.origin, size: c.size), c.callout)
        }
        return f
    }

    /// Packs up to four active masks into the layer's shader parameters.
    /// Four is a deliberate limit: more than that on one recording means the
    /// window should have been excluded at capture time instead.
    /// Measures how far the crop moves in one frame and hands the shader a
    /// direction to smear along. Derived from the crop rather than tracked as
    /// state, so scrubbing backwards gives the identical frame.
    private func applyMotion(to layer: inout LayerParams, at t: Double, crop: CGRect) {
        guard motionBlur > 0.001 else { return }
        let dt = 1.0 / 60.0
        let prev = self.crop(at: max(0, t - dt))

        // Both the pan and the scale change contribute: a zoom smears outward
        // from the centre even when the camera is not panning.
        let dx = crop.midX - prev.midX
        let dy = crop.midY - prev.midY
        let dScale = (crop.width - prev.width) / max(crop.width, 1)
        let radial = dScale * crop.width * 0.5

        let mag = hypot(dx, dy) + abs(radial)
        guard mag > 0.35 else { return }   // still camera: leave it sharp

        layer.motion = SIMD2(Float(dx + radial), Float(dy + radial * (crop.height / max(crop.width, 1))))
        layer.motionScale = Float(motionBlur)
    }

    private func applyMasks(to layer: inout LayerParams, at t: Double) {
        let active = masks.filter { t >= $0.start && t <= $0.end }.prefix(4)
        var rects = [SIMD4<Float>](repeating: SIMD4<Float>(), count: 4)
        var strengths = SIMD4<Float>()
        for (i, m) in active.enumerated() where m.rect.count == 4 {
            rects[i] = SIMD4(Float(m.rect[0] * sourceSize.width),
                             Float(m.rect[1] * sourceSize.height),
                             Float(m.rect[2] * sourceSize.width),
                             Float(m.rect[3] * sourceSize.height))
            // Sign carries the style, which keeps the shader struct small.
            strengths[i] = m.style == "blur" ? -Float(m.strength) : Float(m.strength)
        }
        layer.mask0 = rects[0]
        layer.mask1 = rects[1]
        layer.mask2 = rects[2]
        layer.mask3 = rects[3]
        layer.maskStrength = strengths
    }

    public func crop(at t: Double) -> CGRect {
        let full = CGRect(origin: .zero, size: sourceSize)
        guard let zoom = zooms.first(where: { t >= $0.start && t <= $0.end }) else { return full }

        let z = level(at: t, zoom: zoom)
        guard z > 1.0001 else { return full }

        let size = CGSize(width: sourceSize.width / z, height: sourceSize.height / z)
        let centre = (zoom.follow != nil ? focus(at: t) : nil)
            ?? CGPoint(x: zoom.anchor[0] * sourceSize.width,
                       y: zoom.anchor[1] * sourceSize.height)

        // Clamp after smoothing, never before, or the camera swings off the
        // edge of the screen when you click near a corner.
        let x = min(max(centre.x - size.width / 2, 0), sourceSize.width - size.width)
        let y = min(max(centre.y - size.height / 2, 0), sourceSize.height - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
