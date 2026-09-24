import Foundation
import CoreGraphics

/// Turns recorded clicks into zoom keyframes. This is the feature that makes
/// the tool feel expensive: record normally, open the editor, the zooms are
/// already placed.
public enum AutoZoom {

    public struct Tuning {
        public var maxGap = 2.5          // seconds between clicks in one cluster
        public var maxDistance = 800.0   // source pixels between clicks in one cluster
        public var leadIn = 0.4          // start zooming before the first click
        public var tailOut = 1.2         // hold after the last click
        public var mergeGap = 1.0        // join zooms closer than this
        public var minLevel = 1.4
        public var maxLevel = 2.5
        public init() {}
    }

    public static func generate(clicks: [(t: Double, p: CGPoint)],
                                sourceSize: CGSize,
                                duration: Double,
                                tuning: Tuning = Tuning()) -> [Zoom] {
        guard !clicks.isEmpty else { return [] }
        let sorted = clicks.sorted { $0.t < $1.t }

        // Collapse double clicks: they are one intent, not two.
        var events: [(t: Double, p: CGPoint)] = []
        for c in sorted {
            if let last = events.last, c.t - last.t < 0.3,
               hypot(c.p.x - last.p.x, c.p.y - last.p.y) < 20 { continue }
            events.append(c)
        }

        var clusters: [[(t: Double, p: CGPoint)]] = []
        for e in events {
            if var cur = clusters.last, let last = cur.last,
               e.t - last.t < tuning.maxGap,
               hypot(e.p.x - last.p.x, e.p.y - last.p.y) < tuning.maxDistance {
                cur.append(e)
                clusters[clusters.count - 1] = cur
            } else {
                clusters.append([e])
            }
        }

        var zooms: [Zoom] = []
        for c in clusters {
            let start = max(0, c[0].t - tuning.leadIn)
            let end = min(duration, c[c.count - 1].t + tuning.tailOut)
            guard end - start > 0.5 else { continue }

            let cx = c.map { $0.p.x }.reduce(0, +) / Double(c.count)
            let cy = c.map { $0.p.y }.reduce(0, +) / Double(c.count)

            // Spread out the zoom when the clicks are spread out, otherwise a
            // burst of clicks across a form gets uncomfortably tight.
            let spreadX = (c.map { $0.p.x }.max() ?? cx) - (c.map { $0.p.x }.min() ?? cx)
            let spreadY = (c.map { $0.p.y }.max() ?? cy) - (c.map { $0.p.y }.min() ?? cy)
            let spread = max(max(spreadX, spreadY), 1)
            let fit = min(sourceSize.width, sourceSize.height) / (spread * 2.2)
            let level = min(max(fit, tuning.minLevel), tuning.maxLevel)

            var z = Zoom(start: start, end: end, level: level)
            z.anchor = [cx / sourceSize.width, cy / sourceSize.height]

            // Extend rather than overlap: two zooms fighting over the same
            // moment looks like a glitch.
            if var prev = zooms.last, start - prev.end < tuning.mergeGap {
                prev.end = end
                prev.level = max(prev.level, level)
                zooms[zooms.count - 1] = prev
            } else {
                zooms.append(z)
            }
        }
        return zooms
    }

    /// Zooms for a phone take: the camera pushes in on the whole phone
    /// rather than cropping inside it, so one level suits every tap, and
    /// taps close together in time share one zoom that pans between them.
    public static func phone(clicks: [(t: Double, p: CGPoint)], sourceSize: CGSize,
                             duration: Double, level: Double = 1.6) -> [Zoom] {
        let sorted = clicks.sorted { $0.t < $1.t }
        var zooms: [Zoom] = []
        for c in sorted {
            let start = max(0, c.t - 0.45)
            let end = min(duration, c.t + 1.3)
            guard end - start > 0.6 else { continue }
            if var prev = zooms.last, start - prev.end < 1.2 {
                prev.end = end
                zooms[zooms.count - 1] = prev
                continue
            }
            var z = Zoom(start: start, end: end, level: level)
            z.anchor = [c.p.x / sourceSize.width, c.p.y / sourceSize.height]
            z.follow = nil
            z.inDuration = 0.5
            z.outDuration = 0.6
            zooms.append(z)
        }
        return zooms
    }
}
