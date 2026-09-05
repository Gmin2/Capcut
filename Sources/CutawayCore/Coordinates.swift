import Foundation
import AppKit

/// Every point conversion in the project goes through here. Doing the y-flip
/// inline anywhere else is how retina/multi-display coordinate bugs start.
public struct CaptureSpace {
    public let screenFrame: CGRect   // AppKit points, y-up, global
    public let scale: CGFloat        // backing scale factor
    public let pixelSize: CGSize     // capture buffer size

    public init(screenFrame: CGRect, scale: CGFloat) {
        self.screenFrame = screenFrame
        self.scale = scale
        self.pixelSize = CGSize(width: screenFrame.width * scale,
                                height: screenFrame.height * scale)
    }

    /// AppKit global screen point (origin bottom-left) -> capture pixel
    /// (origin top-left), which is what the video frames use.
    public func pixels(from p: NSPoint) -> CGPoint {
        CGPoint(x: (p.x - screenFrame.minX) * scale,
                y: (screenFrame.maxY - p.y) * scale)
    }

    /// Capture pixel -> 0...1 normalised, which is what project.json stores so
    /// edits survive a change of output resolution.
    public func normalised(from p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / pixelSize.width, y: p.y / pixelSize.height)
    }
}
