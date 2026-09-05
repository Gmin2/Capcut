import Foundation
import AppKit
import CoreMedia

/// Records what the user did, alongside the video. This is the file that makes
/// auto-zoom and AI editing possible: together with a transcript it is a
/// complete textual description of the recording, so an editor never has to
/// look at a pixel.
public final class EventRecorder {

    public struct CursorSample: Codable { let t: Double; let x: Double; let y: Double }
    public struct Click: Codable {
        let t: Double; let x: Double; let y: Double
        let button: String; let clickCount: Int
    }
    public struct AppSwitch: Codable { let t: Double; let bundleId: String; let name: String }

    public struct Events: Codable {
        let version: Int
        let displayPixelSize: [Double]
        let backingScale: Double
        let duration: Double
        let cursor: [CursorSample]
        let clicks: [Click]
        let apps: [AppSwitch]
    }

    private let space: CaptureSpace
    private let hostClock = CMClockGetHostTimeClock()
    private var anchor = CMTime.zero          // first video frame PTS

    private var cursor: [CursorSample] = []
    private var clicks: [Click] = []
    private var apps: [AppSwitch] = []

    private var timer: DispatchSourceTimer?
    private var monitors: [Any] = []
    private var appObserver: NSObjectProtocol?
    private let lock = NSLock()

    public init(space: CaptureSpace) { self.space = space }

    /// `anchor` must be the presentation timestamp of the first video frame,
    /// not the time capture was requested. There is a warmup between the two,
    /// and using the wrong one puts every event a fixed offset out.
    public func start(anchor: CMTime) {
        self.anchor = anchor

        // Sampled on a fixed timer rather than driven by .mouseMoved events:
        // move events are irregular, stop entirely when the pointer is still,
        // and miss motion over some system surfaces. A regular grid also makes
        // interpolation at render time trivial.
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(8))   // 120 Hz
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let p = self.space.pixels(from: NSEvent.mouseLocation)
            self.lock.lock()
            self.cursor.append(CursorSample(t: self.now(), x: p.x, y: p.y))
            self.lock.unlock()
        }
        t.resume()
        timer = t

        // Mouse monitoring needs no TCC permission. Only .keyDown would, which
        // is why keycast is a separate opt-in later.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            guard let self else { return }
            let p = self.space.pixels(from: NSEvent.mouseLocation)
            let button = e.type == .rightMouseDown ? "right"
                       : e.type == .leftMouseDown ? "left" : "other"
            self.lock.lock()
            self.clicks.append(Click(t: self.now(), x: p.x, y: p.y,
                                     button: button, clickCount: e.clickCount))
            self.lock.unlock()
        }) { monitors.append(m) }

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self.lock.lock()
            self.apps.append(AppSwitch(t: self.now(),
                                       bundleId: app.bundleIdentifier ?? "",
                                       name: app.localizedName ?? ""))
            self.lock.unlock()
        }
    }

    private func now() -> Double {
        CMTimeGetSeconds(CMClockGetTime(hostClock) - anchor)
    }

    public func stop(duration: Double, to url: URL) throws {
        timer?.cancel(); timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let o = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }

        lock.lock()
        let events = Events(
            version: 1,
            displayPixelSize: [space.pixelSize.width, space.pixelSize.height],
            backingScale: Double(space.scale),
            duration: duration,
            cursor: cursor, clicks: clicks, apps: apps)
        lock.unlock()

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(events).write(to: url)

        Log.line("events: \(cursor.count) cursor, \(clicks.count) clicks, \(apps.count) app switches")
    }
}
