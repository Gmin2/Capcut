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
        /// "gradient", "solid", "blurredScreen" or "image".
        public var kind: String = "gradient"
        /// Path to a background image, used when kind is "image".
        public var image: String?
        /// Film grain. Cheap insurance against banding on a wide gradient.
        public var grain: Double = 0.012
        /// Darkens a blurred or image backdrop so the plate still reads as the
        /// subject rather than competing with it.
        public var dim: Double = 0.35

        public init(from: String, to: String, angle: Double,
                    kind: String = "gradient", image: String? = nil,
                    grain: Double = 0.012, dim: Double = 0.35) {
            self.from = from
            self.to = to
            self.angle = angle
            self.kind = kind
            self.image = image
            self.grain = grain
            self.dim = dim
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            from = (try? c.decode(String.self, forKey: .from)) ?? "#3B1D6E"
            to = (try? c.decode(String.self, forKey: .to)) ?? "#0B1120"
            angle = (try? c.decode(Double.self, forKey: .angle)) ?? 135
            kind = (try? c.decode(String.self, forKey: .kind)) ?? "gradient"
            image = try? c.decode(String.self, forKey: .image)
            grain = (try? c.decode(Double.self, forKey: .grain)) ?? 0.012
            dim = (try? c.decode(Double.self, forKey: .dim)) ?? 0.35
        }
    }

    public var background: Gradient

    public static let `default` = Style(
        background: .init(from: "#3B1D6E", to: "#0B1120", angle: 135))

    /// Ready-made looks, so a project does not have to invent a palette.
    public static let presets: [String: Gradient] = [
        "midnight":  .init(from: "#3B1D6E", to: "#0B1120", angle: 135),
        "slate":     .init(from: "#2B3440", to: "#12171D", angle: 120),
        "ember":     .init(from: "#7A2E1E", to: "#160D12", angle: 140),
        "forest":    .init(from: "#0F3D3E", to: "#08131A", angle: 120),
        "paper":     .init(from: "#EDE7DC", to: "#CFC6B6", angle: 115,
                           grain: 0.02, dim: 0),
        "ink":       .init(from: "#0B0D10", to: "#0B0D10", angle: 0, kind: "solid"),
        "screen":    .init(from: "#000000", to: "#000000", angle: 0,
                           kind: "blurredScreen"),
    ]

    public func backgroundParams(outputSize: CGSize,
                                 sourceSize: CGSize = .zero) -> BackgroundParams {
        var p = BackgroundParams()
        p.bg0 = Style.rgba(background.from)
        p.bg1 = Style.rgba(background.to)
        p.angle = Float(background.angle)
        p.outputSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        p.sourceSize = SIMD2(Float(max(sourceSize.width, 1)),
                             Float(max(sourceSize.height, 1)))
        p.grain = Float(background.grain)
        p.dim = Float(background.dim)
        switch background.kind {
        case "solid":         p.kind = 1
        case "blurredScreen": p.kind = 2
        case "image":         p.kind = 3
        default:              p.kind = 0
        }
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
