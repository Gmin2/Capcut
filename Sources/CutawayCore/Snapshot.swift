import Foundation
import ScreenCaptureKit
import AppKit

/// One-shot screen grab. Used for timeline thumbnails later, and right now for
/// looking at the app's own window during development.
public enum Snapshot {
    /// Captures one app's frontmost window even when another window covers it.
    public static func captureWindow(bundleID: String, titled: String? = nil, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows
            // this process only, another copy of the app may have a window open too
            .filter({ $0.owningApplication?.bundleIdentifier == bundleID
                      && $0.owningApplication?.processID == getpid() && $0.frame.width > 400
                      && (titled == nil || $0.title == titled) })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw NSError(domain: "cutaway", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: "no window for \(bundleID)"])
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        try Still.write(image, to: url)
        Log.line("window snapshot \(image.width)x\(image.height)")
    }

    public static func captureDisplay(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = Recorder.pickDisplay(content, id: nil) else {
            throw NSError(domain: "cutaway", code: 40)
        }
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        try Still.write(image, to: url)
        Log.line("snapshot \(image.width)x\(image.height) -> \(url.lastPathComponent)")
    }
}
