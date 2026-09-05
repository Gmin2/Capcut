import Foundation
import CoreGraphics

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
public final class Timeline: @unchecked Sendable {
    public let zooms: [Zoom]
    public let sourceSize: CGSize

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
