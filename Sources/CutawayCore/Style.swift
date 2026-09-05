import Foundation
import CoreGraphics
import simd

/// The look of the video: the canvas behind everything. Per-layer appearance
/// lives in `Placement` now, since each layer can differ.
public struct Style: Codable {
    public struct Gradient: Codable {
        public var from: String
        public var to: String
        public var angle: Double   // degrees
    }

    public var background: Gradient

    public static let `default` = Style(
        background: .init(from: "#3B1D6E", to: "#0B1120", angle: 135))

    public func backgroundParams(outputSize: CGSize) -> BackgroundParams {
        var p = BackgroundParams()
        p.bg0 = Style.rgba(background.from)
        p.bg1 = Style.rgba(background.to)
        p.angle = Float(background.angle)
        p.outputSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        return p
    }

    /// "#RRGGBB" or "#RRGGBBAA".
    public static func rgba(_ hex: String) -> SIMD4<Float> {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 6 { s += "FF" }
        guard s.count == 8, let v = UInt32(s, radix: 16) else { return SIMD4(1, 0, 1, 1) }
        return SIMD4(Float((v >> 24) & 0xFF) / 255, Float((v >> 16) & 0xFF) / 255,
                     Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }
}
