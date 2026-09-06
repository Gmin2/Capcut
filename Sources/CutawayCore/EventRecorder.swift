import Foundation
import AppKit
import IOKit.hid
import CoreMedia

/// Records what the user did, alongside the video. This is the file that makes
/// auto-zoom and AI editing possible: together with a transcript it is a
/// complete textual description of the recording, so an editor never has to
/// look at a pixel.
public final class EventRecorder {

    public struct CursorSample: Codable { public let t: Double; public let x: Double; public let y: Double }
    public struct Click: Codable {
        public let t: Double; public let x: Double; public let y: Double
        public let button: String; public let clickCount: Int
    }
    public struct AppSwitch: Codable { public let t: Double; public let bundleId: String; public let name: String }

    /// One keystroke, already rendered to the label a viewer should see
    /// ("⌘S", "⇧⌥→", "return"). Storing the label rather than the key code
    /// keeps the renderer dumb and the file readable.
    public struct Key: Codable {
        public let t: Double
        public let label: String
        /// True for plain typing, which the overlay coalesces into words
        /// instead of flashing one box per letter.
        public let isText: Bool
    }

    public struct Events: Codable {
        public let version: Int
        public let displayPixelSize: [Double]
        public let backingScale: Double
        public let duration: Double
        public let cursor: [CursorSample]
        public let clicks: [Click]
        public let apps: [AppSwitch]
        public var keys: [Key] = []
    }

    private let space: CaptureSpace
    private let clock: RecordClock

    private var cursor: [CursorSample] = []
    private var clicks: [Click] = []
    private var apps: [AppSwitch] = []
    private var keys: [Key] = []

    private var timer: DispatchSourceTimer?
    private var monitors: [Any] = []
    private var appObserver: NSObjectProtocol?
    private let lock = NSLock()

    /// Off unless asked for: keystroke capture needs Input Monitoring, and a
    /// screen recorder should not demand it just to record a screen.
    public var captureKeys = false

    /// Whether this process may observe keystrokes. Checked without prompting,
    /// so the caller can decide whether asking is worth it.
    public static var canCaptureKeys: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the Input Monitoring prompt. Returns immediately; macOS shows
    /// the dialog and the grant only takes effect on the next launch, so the
    /// caller should say so rather than waiting.
    @discardableResult
    public static func requestKeyAccess() -> Bool {
        if canCaptureKeys { return true }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public init(space: CaptureSpace, clock: RecordClock) {
        self.space = space
        self.clock = clock
    }

    /// `anchor` must be the presentation timestamp of the first video frame,
    /// not the time capture was requested. There is a warmup between the two,
    /// and using the wrong one puts every event a fixed offset out.
    /// Times come from the shared record clock, so events land in the same
    /// timeline as the video and paused spans are excluded from both.
    public func start() {

        // Sampled on a fixed timer rather than driven by .mouseMoved events:
        // move events are irregular, stop entirely when the pointer is still,
        // and miss motion over some system surfaces. A regular grid also makes
        // interpolation at render time trivial.
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(8))   // 120 Hz
        t.setEventHandler { [weak self] in
            guard let self, !self.clock.isPaused else { return }
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
            guard let self, !self.clock.isPaused else { return }
            let p = self.space.pixels(from: NSEvent.mouseLocation)
            let button = e.type == .rightMouseDown ? "right"
                       : e.type == .leftMouseDown ? "left" : "other"
            self.lock.lock()
            self.clicks.append(Click(t: self.now(), x: p.x, y: p.y,
                                     button: button, clickCount: e.clickCount))
            self.lock.unlock()
        }) { monitors.append(m) }

        if captureKeys, EventRecorder.canCaptureKeys {
            let keyMask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
            if let m = NSEvent.addGlobalMonitorForEvents(matching: keyMask, handler: {
                [weak self] e in
                guard let self, !self.clock.isPaused else { return }
                guard let label = KeyLabel.make(from: e) else { return }
                self.lock.lock()
                self.keys.append(Key(t: self.now(), label: label.text,
                                     isText: label.isText))
                self.lock.unlock()
            }) { monitors.append(m) }
        }

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

    private func now() -> Double { clock.elapsed() }

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
            cursor: cursor, clicks: clicks, apps: apps, keys: keys)
        lock.unlock()

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(events).write(to: url)

        Log.line("events: \(cursor.count) cursor, \(clicks.count) clicks, "
                 + "\(apps.count) app switches, \(keys.count) keys")
    }
}
