import Foundation
import ScreenCaptureKit
import AppKit

public enum Probe {

    public static func listContent() async {
        Log.reset()
        do { try await run() } catch {
            Log.line("ERROR: \(error)")
        }
        Log.flush()
    }

    private static func run() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        Log.line("displays: \(content.displays.count)")
        for d in content.displays {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID
            }
            let scale = screen?.backingScaleFactor ?? -1
            Log.line("""
              id=\(d.displayID) \
              size=\(d.width)x\(d.height)pt \
              frame=\(d.frame) \
              scale=\(scale) \
              pixels=\(Int(CGFloat(d.width) * scale))x\(Int(CGFloat(d.height) * scale))
            """)
        }

        Log.line("\nNSScreen: \(NSScreen.screens.count)")
        for s in NSScreen.screens {
            Log.line("  frame=\(s.frame) scale=\(s.backingScaleFactor) name=\(s.localizedName)")
        }

        Log.line("\napplications: \(content.applications.count)")
        Log.line("windows: \(content.windows.count)")
        let interesting = content.windows
            .filter { ($0.title?.isEmpty == false) && $0.frame.width > 200 }
            .prefix(12)
        for w in interesting {
            Log.line("""
              id=\(w.windowID) \
              app=\(w.owningApplication?.applicationName ?? "?") \
              bundle=\(w.owningApplication?.bundleIdentifier ?? "?") \
              title=\(w.title ?? "") \
              frame=\(w.frame)
            """)
        }
    }
}
