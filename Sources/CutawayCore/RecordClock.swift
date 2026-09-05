import Foundation
import CoreMedia

/// Shared time base for a recording session, so pausing removes time from
/// every track at once.
///
/// Rather than stitching segments together afterwards, paused spans are
/// subtracted from presentation timestamps as samples arrive. The result is a
/// single continuous file that behaves as if the pause never happened, which is
/// what "pause, then carry on from there" should mean.
public final class RecordClock: @unchecked Sendable {

    private let lock = NSLock()
    private var pausedTotal = CMTime.zero
    private var pauseStart: CMTime?

    /// First screen frame. Everything is measured from here.
    public private(set) var anchor = CMTime.zero
    private var anchorSet = false

    public init() {}

    public static func now() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    public func setAnchorIfNeeded(_ t: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard !anchorSet else { return }
        anchor = t
        anchorSet = true
    }

    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return pauseStart != nil
    }

    public func pause() {
        lock.lock(); defer { lock.unlock() }
        guard pauseStart == nil else { return }
        pauseStart = RecordClock.now()
    }

    public func resume() {
        lock.lock(); defer { lock.unlock() }
        guard let start = pauseStart else { return }
        pausedTotal = pausedTotal + (RecordClock.now() - start)
        pauseStart = nil
    }

    /// Wall-clock timestamp with all paused time removed.
    public func adjusted(_ pts: CMTime) -> CMTime {
        lock.lock(); defer { lock.unlock() }
        return pts - pausedTotal
    }

    /// Seconds since the anchor, paused time excluded. This is "source time"
    /// for every event and every keyframe.
    public func elapsed(_ pts: CMTime = RecordClock.now()) -> Double {
        lock.lock(); defer { lock.unlock() }
        return CMTimeGetSeconds(pts - pausedTotal - anchor)
    }

    /// Total paused time so far, as a CMTime, for retiming sample buffers.
    public var pausedOffset: CMTime {
        lock.lock(); defer { lock.unlock() }
        return pausedTotal
    }

    public var pausedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return CMTimeGetSeconds(pausedTotal)
    }
}
