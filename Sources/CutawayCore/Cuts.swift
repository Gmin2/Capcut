import Foundation

/// Editing by cutting spans out of the take.
///
/// Nothing is deleted from the recording: the cut list says which spans of
/// source time survive, so every cut is reversible and the file on disk is
/// never touched.
public enum Cuts {

    /// The whole take when a project has no cut list yet.
    public static func base(_ segments: [Segment], duration: Double) -> [Segment] {
        segments.isEmpty ? [Segment(sourceStart: 0, sourceEnd: duration)] : segments
    }

    /// Takes a span of source time out of the cut list.
    public static func remove(_ span: ClosedRange<Double>, from segments: [Segment],
                              duration: Double) -> [Segment] {
        var out: [Segment] = []
        for s in base(segments, duration: duration) {
            // the span misses this piece entirely
            if span.upperBound <= s.sourceStart || span.lowerBound >= s.sourceEnd {
                out.append(s)
                continue
            }
            // what is left in front of the cut
            if span.lowerBound > s.sourceStart + 0.01 {
                var head = s
                head.sourceEnd = span.lowerBound
                out.append(head)
            }
            // and behind it
            if span.upperBound < s.sourceEnd - 0.01 {
                var tail = s
                tail.sourceStart = span.upperBound
                out.append(tail)
            }
        }
        return out
    }

    /// Puts a span back, merging it with anything it now touches.
    public static func restore(_ span: ClosedRange<Double>, into segments: [Segment],
                               duration: Double) -> [Segment] {
        var all = base(segments, duration: duration)
        all.append(Segment(sourceStart: span.lowerBound, sourceEnd: span.upperBound))
        all.sort { $0.sourceStart < $1.sourceStart }

        var merged: [Segment] = []
        for s in all {
            guard var last = merged.last, s.sourceStart <= last.sourceEnd + 0.01,
                  abs(last.speed - s.speed) < 0.01 else {
                merged.append(s)
                continue
            }
            last.sourceEnd = max(last.sourceEnd, s.sourceEnd)
            merged[merged.count - 1] = last
        }
        return merged
    }

    /// True when this moment survives the current cut list.
    public static func isKept(_ t: Double, in segments: [Segment], duration: Double) -> Bool {
        base(segments, duration: duration).contains { t >= $0.sourceStart - 0.01 && t <= $0.sourceEnd + 0.01 }
    }

    /// The noises people make while thinking. Removing them is the single
    /// biggest improvement to a first take.
    public static let fillers: Set<String> = [
        "um", "uh", "erm", "er", "ah", "hmm", "mmm", "uhh", "umm", "eh",
    ]

    /// Spans of a transcript that are only filler, with a little air either
    /// side so the cut does not clip the word before it.
    public static func fillerSpans(in transcript: Transcript, padding: Double = 0.04)
    -> [ClosedRange<Double>] {
        transcript.segments.compactMap { word in
            let clean = word.text.lowercased()
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard fillers.contains(clean) else { return nil }
            let a = max(0, word.t - padding)
            let b = word.t + word.duration + padding
            return b > a ? a...b : nil
        }
    }

    /// Gaps between spoken words longer than `longerThan`, trimmed to leave
    /// `keep` seconds of breathing room.
    public static func silences(in transcript: Transcript, duration: Double,
                                longerThan: Double = 0.7, keep: Double = 0.18)
    -> [ClosedRange<Double>] {
        let words = transcript.segments.sorted { $0.t < $1.t }
        guard !words.isEmpty else { return [] }

        var out: [ClosedRange<Double>] = []
        var previousEnd = 0.0
        for word in words {
            let gap = word.t - previousEnd
            if gap > longerThan {
                let a = previousEnd + keep
                let b = word.t - keep
                if b > a { out.append(a...b) }
            }
            previousEnd = max(previousEnd, word.t + word.duration)
        }
        let tail = duration - previousEnd
        if tail > longerThan {
            out.append((previousEnd + keep)...(duration - keep))
        }
        return out
    }

    /// Applies a run of cuts in one go, back to front so earlier spans keep
    /// their times.
    public static func removeAll(_ spans: [ClosedRange<Double>], from segments: [Segment],
                                 duration: Double) -> [Segment] {
        var out = base(segments, duration: duration)
        for span in spans.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            out = remove(span, from: out, duration: duration)
        }
        return out
    }

    /// How much of the take survives, for telling someone what a cut did.
    public static func kept(_ segments: [Segment], duration: Double) -> Double {
        base(segments, duration: duration).reduce(0) { $0 + ($1.sourceEnd - $1.sourceStart) }
    }
}
