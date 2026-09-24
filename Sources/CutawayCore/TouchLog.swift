import Foundation
import CoreGraphics

/// A finger going down on a phone screen, in screen pixels.
public struct Tap: Equatable {
    /// Seconds on whatever clock the source uses: the device's kernel clock
    /// for android, the mac's for the simulator. The recorder moves it onto
    /// the video's timeline.
    public var t: Double
    public var x: Double
    public var y: Double
}

/// Reads `adb shell getevent -lt` a line at a time and emits a tap for every
/// new touch. Works off the kernel's own input events, so taps land at the
/// exact pixel whether they came from a mouse on the emulator window or a
/// finger on a real phone.
public struct GetEventParser {

    /// Raw axis range of one touch device, from `getevent -pl`. The emulator
    /// reports 0...32767 whatever the screen size, real phones mostly report
    /// pixels, so this is always read rather than assumed.
    public struct Axes: Equatable {
        public var x: ClosedRange<Double>
        public var y: ClosedRange<Double>
    }

    public let screen: CGSize
    public private(set) var axes: [String: Axes]

    private var lastX: [String: Double] = [:]
    private var lastY: [String: Double] = [:]
    private var down: Set<String> = []
    private var fresh: Set<String> = []
    /// The smallest gap seen between when a line arrived and the device time
    /// it carries. Lines stream within a few milliseconds, so the minimum is
    /// a good estimate of the clock offset between device and mac.
    public private(set) var clockOffset: Double?

    public init(screen: CGSize, axes: [String: Axes]) {
        self.screen = screen
        self.axes = axes
    }

    /// Parses the capability dump from `getevent -pl` into the axis range of
    /// every device that reports multitouch positions.
    public static func axes(fromCapabilities text: String) -> [String: Axes] {
        var out: [String: Axes] = [:]
        var device: String?
        var x: ClosedRange<Double>?
        var y: ClosedRange<Double>?

        func flush() {
            if let device, let x, let y { out[device] = Axes(x: x, y: y) }
            x = nil
            y = nil
        }
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("add device"), let path = line.split(separator: " ").last {
                flush()
                device = String(path)
                continue
            }
            if line.contains("ABS_MT_POSITION_X") { x = range(in: line) }
            if line.contains("ABS_MT_POSITION_Y") { y = range(in: line) }
        }
        flush()
        return out
    }

    private static func range(in line: String) -> ClosedRange<Double>? {
        func number(after key: String) -> Double? {
            guard let r = line.range(of: key) else { return nil }
            let rest = line[r.upperBound...].prefix { $0.isNumber || $0 == "-" }
            return Double(rest)
        }
        guard let lo = number(after: "min "), let hi = number(after: "max "), hi > lo else {
            return nil
        }
        return lo...hi
    }

    /// Feeds one line of `getevent -lt`. `received` is the mac time the line
    /// came in, used only to estimate the clock offset.
    public mutating func feed(_ line: String, received: Double? = nil) -> Tap? {
        // [      32.305634] /dev/input/event1: EV_ABS       ABS_MT_POSITION_X    00003fff
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let stamp = line[line.index(after: line.startIndex)..<close]
            .trimmingCharacters(in: .whitespaces)
        guard let t = Double(stamp) else { return nil }
        if let received {
            clockOffset = min(clockOffset ?? .infinity, received - t)
        }

        let fields = line[line.index(after: close)...].split(separator: " ")
        guard fields.count >= 4 else { return nil }
        let device = String(fields[0].dropLast())   // trailing colon
        let code = fields[2]
        let value = String(fields[3])

        switch code {
        case "ABS_MT_TRACKING_ID":
            if value == "ffffffff" {
                down.remove(device)
            } else if !down.contains(device) {
                down.insert(device)
                fresh.insert(device)
            }
        case "ABS_MT_POSITION_X":
            lastX[device] = Double(UInt32(value, radix: 16) ?? 0)
        case "ABS_MT_POSITION_Y":
            lastY[device] = Double(UInt32(value, radix: 16) ?? 0)
        case "SYN_REPORT":
            // A report closes a frame of axis updates, so this is the first
            // moment the new touch's position is complete.
            guard fresh.contains(device), let rx = lastX[device], let ry = lastY[device]
            else { return nil }
            fresh.remove(device)
            let a = axes[device] ?? Axes(x: 0...Double(screen.width), y: 0...Double(screen.height))
            let px = (rx - a.x.lowerBound) / (a.x.upperBound - a.x.lowerBound) * Double(screen.width)
            let py = (ry - a.y.lowerBound) / (a.y.upperBound - a.y.lowerBound) * Double(screen.height)
            return Tap(t: t, x: px.rounded(), y: py.rounded())
        default:
            break
        }
        return nil
    }
}

/// Where the simulated screen sits inside a Simulator window, so a click on
/// the window becomes a tap on the phone.
///
/// Only works with the device bezel turned off, when the window is the
/// screen plus a title bar. The title bar height is whatever is left over
/// once the screen's own aspect is taken out of the window, so nothing about
/// the window chrome is hard coded.
public struct SimulatorWindow {
    /// Window bounds in global display points, origin top left.
    public var bounds: CGRect
    public var screen: CGSize

    public init(bounds: CGRect, screen: CGSize) {
        self.bounds = bounds
        self.screen = screen
    }

    public var titleBar: Double {
        Double(bounds.height) - Double(bounds.width) * Double(screen.height / screen.width)
    }

    /// False when the window cannot be the bare screen, which is what the
    /// bezel being on looks like.
    public var isBareScreen: Bool { titleBar >= 0 && titleBar < 80 }

    /// A point in global display points to screen pixels, or nil when it is
    /// outside the screen (the title bar, or another window).
    public func pixel(for p: CGPoint) -> CGPoint? {
        guard isBareScreen else { return nil }
        let top = Double(bounds.minY) + titleBar
        let fx = (Double(p.x) - Double(bounds.minX)) / Double(bounds.width)
        let fy = (Double(p.y) - top) / (Double(bounds.maxY) - top)
        guard (0...1).contains(fx), (0...1).contains(fy) else { return nil }
        return CGPoint(x: (fx * Double(screen.width)).rounded(),
                       y: (fy * Double(screen.height)).rounded())
    }
}

/// Recording chunks and the taps within them, put on one timeline.
///
/// Android's screenrecord stops every three minutes, so a long take is
/// several files played back to back. Each one starts at its own moment on
/// the mac's clock; a tap belongs to whichever chunk was running.
public struct ChunkClock {
    public struct Chunk {
        public var start: Double
        public var end: Double
        public var duration: Double { max(0, end - start) }
    }

    public var chunks: [Chunk]

    public init(chunks: [Chunk]) { self.chunks = chunks }

    public var duration: Double { chunks.reduce(0) { $0 + $1.duration } }

    /// A mac time to seconds into the joined video, or nil between chunks.
    public func videoTime(forHost h: Double) -> Double? {
        var before = 0.0
        for c in chunks {
            if h >= c.start && h <= c.end { return before + (h - c.start) }
            before += c.duration
        }
        return nil
    }
}
