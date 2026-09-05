import Foundation
import AppKit
import CoreGraphics
import simd

/// How the pointer is drawn. We record with the real cursor excluded, so this
/// is drawn at render time: bigger than life, lightly smoothed, and with a
/// ripple on click. It is the cheapest large jump in perceived quality.
public struct CursorStyle: Codable {
    public var visible = true
    /// Multiplier on a 40px-tall pointer at 1080p. 1.7 reads well.
    public var scale: Double = 1.7
    /// 0 = raw recorded position, 1 = heavily smoothed. Light smoothing removes
    /// sensor jitter without introducing visible lag.
    public var smoothing: Double = 0.45
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

    /// Drawn as vectors at high resolution rather than reusing the system
    /// pointer, whose image is only 56x80 and goes soft the moment it is scaled
    /// up. Same silhouette, but with a real outline and a soft shadow so it
    /// stays readable over both light and dark screen content.
    static let arrowPath: [CGPoint] = [
        CGPoint(x: 0.000, y: 0.000),   // tip, and the hot spot
        CGPoint(x: 0.000, y: 0.735),
        CGPoint(x: 0.205, y: 0.573),
        CGPoint(x: 0.327, y: 0.862),
        CGPoint(x: 0.475, y: 0.800),
        CGPoint(x: 0.354, y: 0.520),
        CGPoint(x: 0.575, y: 0.508),
    ]

    /// Clear space kept around the arrow so the shadow is not clipped by the
    /// texture edge, as a fraction of canvas height.
    static let padding: CGFloat = 0.13
    static let canvas = CGSize(width: 340, height: 500)

    /// Aspect only. The on-screen size comes from CursorStyle.scale, so
    /// changing the texture resolution never changes how big the pointer looks.
    public static var size: CGSize { canvas }

    /// Height of the pointer in output pixels at 1080p and scale 1.0.
    public static let baseHeight: Double = 40

    public static var hotSpotFraction: CGPoint {
        CGPoint(x: padding * canvas.height / canvas.width, y: padding)
    }

    public static func makeCGImage() -> CGImage? {
        let w = Int(canvas.width), h = Int(canvas.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Top-left origin, so the path reads the same way as every other
        // coordinate in this project.
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)

        let pad = padding * canvas.height
        let scale = canvas.height - pad * 2
        let path = CGMutablePath()
        for (i, p) in arrowPath.enumerated() {
            let pt = CGPoint(x: pad + p.x * scale, y: pad + p.y * scale)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()

        ctx.setShadow(offset: CGSize(width: 0, height: -scale * 0.020),
                      blur: scale * 0.055,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()

        // Outline after the fill so the shadow does not double up on it.
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 0.9))
        ctx.setLineWidth(scale * 0.019)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()

        return ctx.makeImage()
    }
}
