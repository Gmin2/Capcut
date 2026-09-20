import Foundation

/// A kept span of the recording, optionally sped up. Everything not covered by
/// a segment is simply not in the output, which is how cuts and dead-air
/// removal are expressed.
public struct Segment: Codable {
    public var sourceStart: Double
    public var sourceEnd: Double
    /// 1 is real time. 4 plays that span at four times speed, which is usually
    /// nicer than cutting outright when something is happening but slowly.
    public var speed: Double = 1.0
    public var note: String?

    public init(sourceStart: Double, sourceEnd: Double, speed: Double = 1.0,
                note: String? = nil) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = speed
        self.note = note
    }

    var sourceDuration: Double { max(0, sourceEnd - sourceStart) }
    var outputDuration: Double { sourceDuration / max(speed, 0.01) }
}

/// Maps between the edited timeline the viewer sees and the raw recording.
///
/// Every effect is stored in *source* time, so moving or deleting a segment
/// never requires rewriting a single keyframe. This is the piece that makes
/// that possible, and getting it wrong is what makes zooms drift after a cut.
public struct TimeMap {
    public let segments: [Segment]
    public let outputDuration: Double
    private let starts: [Double]      // cumulative output start per segment

    public init(segments: [Segment], sourceDuration: Double) {
        let cleaned = segments
            .filter { $0.sourceDuration > 0.01 }
            .sorted { $0.sourceStart < $1.sourceStart }
        let effective = cleaned.isEmpty
            ? [Segment(sourceStart: 0, sourceEnd: sourceDuration)]
            : cleaned
        self.segments = effective

        var acc: [Double] = []
        var total = 0.0
        for s in effective {
            acc.append(total)
            total += s.outputDuration
        }
        starts = acc
        outputDuration = total
    }

    public var isIdentity: Bool {
        segments.count == 1 && segments[0].speed == 1.0
    }

    public func sourceTime(forOutput t: Double) -> Double {
        guard !segments.isEmpty else { return t }
        if t <= 0 { return segments[0].sourceStart }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        let s = segments[lo]
        let into = (t - starts[lo]) * s.speed
        return min(s.sourceStart + into, s.sourceEnd)
    }

    /// Where a source moment ends up in the output, or nil if it was cut.
    public func outputTime(forSource t: Double) -> Double? {
        for (i, s) in segments.enumerated() where t >= s.sourceStart && t <= s.sourceEnd {
            return starts[i] + (t - s.sourceStart) / max(s.speed, 0.01)
        }
        return nil
    }
}

/// Finds the parts of a recording nobody wants to watch.
/// A region of the screen hidden after the fact. Window exclusion at capture
/// time is always better, because the pixels never exist; this is for what you
/// only noticed afterwards.
public struct Mask: Codable {
    /// Normalised to the *source* frame, so a mask stays on the thing it hides
    /// even while the camera zooms and pans.
    public var rect: [Double]
    public var start: Double = 0
    public var end: Double = .greatestFiniteMagnitude
    /// "mosaic" or "blur". Mosaic is the safer default: a blur can sometimes
    /// be inverted, a large enough mosaic cannot.
    public var style: String = "mosaic"
    public var strength: Double = 26

    public init(rect: [Double], start: Double = 0,
                end: Double = .greatestFiniteMagnitude,
                style: String = "mosaic", strength: Double = 26) {
        self.rect = rect
        self.start = start
        self.end = end
        self.style = style
        self.strength = strength
    }
}

public enum AutoCut {

    public struct Tuning {
        /// Silence shorter than this is natural speech rhythm, not dead air.
        public var minGap = 1.6
        /// Leave a little air either side so cuts do not clip words or clicks.
        public var padding = 0.25
        /// Gaps longer than this are cut outright; shorter ones are sped up,
        /// which keeps continuity when something is still happening on screen.
        public var cutAbove = 4.0
        public var speedUp = 4.0
        /// Cursor movement above this many pixels/second counts as activity.
        public var motionThreshold = 220.0
        public init() {}
    }

    /// A span is dead when nothing was clicked, nothing was typed, the pointer
    /// was effectively still, and nobody was talking. Using the transcript as
    /// well as input events is what stops it cutting the middle of a sentence
    /// delivered over a static screen.
    ///
    /// Built as the complement of the quiet spans: work out what to remove,
    /// then keep everything else. Emitting segments only around gaps loses the
    /// busy material entirely.
    public static func segments(events: Events, transcript: Transcript?,
                                duration: Double,
                                tuning: Tuning = Tuning()) -> [Segment] {
        guard duration > 0 else { return [] }
        let whole = [Segment(sourceStart: 0, sourceEnd: duration)]

        var busy: [(Double, Double)] = []
        for c in events.clicks { busy.append((c.t - 0.3, c.t + 0.6)) }
        for s in transcript?.segments ?? [] {
            busy.append((s.t - 0.15, s.t + s.duration + 0.35))
        }

        // Pointer motion. The threshold is deliberately well above sampling
        // jitter: at 120Hz a couple of pixels of noise reads as hundreds of
        // pixels per second, which would mark the whole recording busy.
        let cur = events.cursor
        if cur.count > 2 {
            for i in 1..<cur.count {
                let dt = cur[i].t - cur[i - 1].t
                guard dt > 0 else { continue }
                let d = hypot(cur[i].p.x - cur[i - 1].p.x, cur[i].p.y - cur[i - 1].p.y)
                if d / dt > tuning.motionThreshold {
                    busy.append((cur[i - 1].t - 0.2, cur[i].t + 0.4))
                }
            }
        }
        guard !busy.isEmpty else { return whole }

        busy.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = [busy[0]]
        for b in busy.dropFirst() {
            if b.0 <= merged[merged.count - 1].1 + 0.05 {
                merged[merged.count - 1].1 = max(merged[merged.count - 1].1, b.1)
            } else {
                merged.append(b)
            }
        }

        // Quiet spans worth acting on, with a little air left either side so a
        // cut never clips a word or a click.
        var quiet: [(a: Double, b: Double, speed: Double, gap: Double)] = []
        var prev = 0.0
        func consider(from: Double, to: Double) {
            let gap = to - from
            guard gap > tuning.minGap else { return }
            let a = from + tuning.padding
            let b = to - tuning.padding
            guard b > a + 0.05 else { return }
            quiet.append((a, b, gap > tuning.cutAbove ? 0 : tuning.speedUp, gap))
        }
        for (s, e) in merged {
            consider(from: prev, to: min(s, duration))
            prev = max(prev, min(e, duration))
        }
        consider(from: prev, to: duration)
        guard !quiet.isEmpty else { return whole }

        var out: [Segment] = []
        var t = 0.0
        for q in quiet {
            if q.a > t { out.append(Segment(sourceStart: t, sourceEnd: q.a)) }
            if q.speed > 0 {
                out.append(Segment(sourceStart: q.a, sourceEnd: q.b, speed: q.speed,
                                   note: String(format: "%.1fs of quiet, sped up %.0fx",
                                                q.gap, q.speed)))
            } else {
                out.append(Segment(sourceStart: q.b, sourceEnd: q.b,
                                   note: String(format: "cut %.1fs of dead air", q.gap)))
            }
            t = q.b
        }
        if t < duration { out.append(Segment(sourceStart: t, sourceEnd: duration)) }

        let kept = out.filter { $0.sourceDuration > 0.01 }
        return kept.isEmpty ? whole : kept
    }
}

extension Double {
    /// 1.5 not 1.5000000001, for anything shown to a person.
    var clean: String {
        self == rounded() ? String(Int(self)) : String(format: "%.2g", self)
    }
}
