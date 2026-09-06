import Foundation
import ScreenCaptureKit
import AppKit

/// One-shot screen grab. Used for timeline thumbnails later, and right now for
/// looking at the app's own window during development.
public enum Snapshot {
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
