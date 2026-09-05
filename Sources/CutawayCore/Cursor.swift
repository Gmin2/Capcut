import Foundation
import AppKit
import CoreGraphics
import simd

/// How the pointer is drawn. We record with the real cursor excluded, so this
/// is drawn at render time: bigger than life, lightly smoothed, and with a
/// ripple on click. It is the cheapest large jump in perceived quality.
public struct CursorStyle: Codable {
    public var visible = true
    /// Multiplier on the macOS pointer size. Around 1.6 reads well at 1080p.
    public var scale: Double = 1.7
    /// 0 = raw recorded position, 1 = heavily smoothed. Light smoothing removes
    /// sensor jitter without introducing visible lag.
    public var smoothing: Double = 0.45
    /// Keeps the pointer the same apparent size regardless of zoom, which is
    /// what people expect; set false to let it scale with the picture.
    public var constantSize = true
    public var clickRipple = true
    public var rippleDuration: Double = 0.45
    public var rippleRadius: Double = 46
    public var rippleColor = "#FFFFFFA6"

    public init() {}
}

public struct CursorParams {
    public var rect = SIMD4<Float>()        // output px: x, y, w, h
    public var rippleColor = SIMD4<Float>()
    public var outputSize = SIMD2<Float>()
    public var ripplePos = SIMD2<Float>()
    public var rippleRadius: Float = 0
    public var rippleAlpha: Float = 0
    public var opacity: Float = 1
    public var pad0: Float = 0
    public init() {}
}

public enum CursorImage {
    /// The real system pointer, so it looks native rather than drawn.
    public static func makeCGImage() -> CGImage? {
        let cursor = NSCursor.arrow
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }
        return cg
    }

    /// The pointer's hotspot as a fraction of the image, so the drawn arrow tip
    /// lands exactly where the recorded coordinate says it was.
    public static var size: CGSize { NSCursor.arrow.image.size }

    public static var hotSpotFraction: CGPoint {
        let c = NSCursor.arrow
        let s = c.image.size
        guard s.width > 0, s.height > 0 else { return .zero }
        return CGPoint(x: c.hotSpot.x / s.width, y: c.hotSpot.y / s.height)
    }
}
