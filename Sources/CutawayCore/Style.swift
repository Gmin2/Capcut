import Foundation
import simd

/// The look of the video. This is the start of project.json, and it is written
/// to be read and edited by an AI as much as by the UI: explicit units, plain
/// numbers, no enums encoded as integers.
public struct Style: Codable {
    public struct Gradient: Codable {
        public var from: String   // "#2E1065"
        public var to: String
        public var angle: Double  // degrees
    }
    public struct Plate: Codable {
        public var padding: Double        // fraction of the shorter output side
        public var cornerRadius: Double   // output pixels
        public var shadowOpacity: Double
        public var shadowRadius: Double   // output pixels
        public var shadowOffsetY: Double  // output pixels
        public var borderWidth: Double
        public var borderColor: String
    }

    public var background: Gradient
    public var plate: Plate

    public static let `default` = Style(
        background: .init(from: "#3B1D6E", to: "#0B1120", angle: 135),
        plate: .init(padding: 0.055, cornerRadius: 18,
                     shadowOpacity: 0.55, shadowRadius: 70, shadowOffsetY: 26,
                     borderWidth: 1.5, borderColor: "#FFFFFF26"))

    /// Resolves style plus a crop rect into GPU parameters. Pure: same inputs
    /// always give the same frame, which is what lets preview and export share
    /// this code and stay identical.
    public func params(outputSize: CGSize, sourceSize: CGSize,
                       crop: CGRect) -> RenderParams {
        var p = RenderParams()
        p.outputSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        p.sourceSize = SIMD2(Float(sourceSize.width), Float(sourceSize.height))
        p.crop = SIMD4(Float(crop.origin.x), Float(crop.origin.y),
                       Float(crop.width), Float(crop.height))

        // Plate keeps the source aspect ratio and is centred, insetting by
        // `padding` on the tighter axis so 16:9 and 16:10 both look deliberate.
        let inset = plate.padding * min(outputSize.width, outputSize.height)
        let avail = CGSize(width: outputSize.width - inset * 2,
                           height: outputSize.height - inset * 2)
        let ar = crop.width / crop.height
        var w = avail.width, h = w / ar
        if h > avail.height { h = avail.height; w = h * ar }
        p.plate = SIMD4(Float((outputSize.width - w) / 2),
                        Float((outputSize.height - h) / 2),
                        Float(w), Float(h))

        p.bg0 = Style.rgba(background.from)
        p.bg1 = Style.rgba(background.to)
        p.bgAngle = Float(background.angle)
        p.cornerRadius = Float(plate.cornerRadius)
        p.shadowRadius = Float(plate.shadowRadius)
        p.shadowOpacity = Float(plate.shadowOpacity)
        p.shadowOffset = SIMD2(0, Float(plate.shadowOffsetY))
        p.borderWidth = Float(plate.borderWidth)
        p.borderColor = Style.rgba(plate.borderColor)
        return p
    }

    /// "#RRGGBB" or "#RRGGBBAA".
    static func rgba(_ hex: String) -> SIMD4<Float> {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 6 { s += "FF" }
        guard s.count == 8, let v = UInt32(s, radix: 16) else { return SIMD4(1, 0, 1, 1) }
        return SIMD4(Float((v >> 24) & 0xFF) / 255, Float((v >> 16) & 0xFF) / 255,
                     Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }
}
