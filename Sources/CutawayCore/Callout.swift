import Foundation
import AppKit
import CoreGraphics
import CoreText
import simd

/// Text on screen: a title, a lower third, a note pointing at what you just
/// clicked. Times are source time like every other effect.
public struct Callout: Codable {
    public var at: Double
    public var duration: Double = 3.0
    public var text: String
    /// Smaller line under the main one. A lower third is usually name + role.
    public var subtitle: String?
    /// "lowerThird", "center", "topLeft", "topCenter", "bottomCenter".
    public var style: String = "lowerThird"
    public var fadeIn: Double = 0.35
    public var fadeOut: Double = 0.45
    public var accent: String?

    public init(at: Double, text: String, subtitle: String? = nil,
                duration: Double = 3.0, style: String = "lowerThird") {
        self.at = at
        self.text = text
        self.subtitle = subtitle
        self.duration = duration
        self.style = style
    }
}

public struct CalloutTheme: Codable {
    public var titleSize: Double = 54
    public var subtitleSize: Double = 30
    public var foreground = "#F4F7FA"
    public var subtitleForeground = "#A9B6C4"
    public var background = "#111820D9"
    public var accent = "#FF7B57"
    public var margin: Double = 0.075
    public init() {}
}

public enum CalloutRenderer {

    /// What to draw at this moment, or nil.
    static func resolve(_ callouts: [Callout], at t: Double, theme: CalloutTheme,
                        outputSize: CGSize) -> (id: String, opacity: Double,
                                                size: CGSize, origin: CGPoint,
                                                callout: Callout)? {
        guard let c = callouts.first(where: { t >= $0.at && t <= $0.at + $0.duration })
        else { return nil }

        // Ease both ends so text never pops.
        let into = t - c.at
        let left = c.at + c.duration - t
        var opacity = 1.0
        if into < c.fadeIn { opacity = CubicBezier.zoomIn.solve(into / max(c.fadeIn, 0.01)) }
        if left < c.fadeOut {
            opacity = min(opacity, CubicBezier.zoomIn.solve(left / max(c.fadeOut, 0.01)))
        }

        let size = measure(c, theme: theme, outputSize: outputSize)
        let margin = theme.margin * outputSize.height
        var origin: CGPoint
        switch c.style {
        case "center":
            origin = CGPoint(x: (outputSize.width - size.width) / 2,
                             y: (outputSize.height - size.height) / 2)
        case "topLeft":
            origin = CGPoint(x: margin, y: margin)
        case "topCenter":
            origin = CGPoint(x: (outputSize.width - size.width) / 2, y: margin)
        case "bottomCenter":
            origin = CGPoint(x: (outputSize.width - size.width) / 2,
                             y: outputSize.height - size.height - margin)
        default:   // lowerThird
            origin = CGPoint(x: margin,
                             y: outputSize.height * 0.72 - size.height / 2)
        }
        // Slide up slightly as it fades in, which reads as deliberate rather
        // than as a dissolve.
        origin.y += (1 - opacity) * 18 * (outputSize.height / 1080)

        let id = "\(c.text)|\(c.subtitle ?? "")|\(c.style)|\(Int(outputSize.height))"
        return (id, opacity, size, origin, c)
    }

    static func fonts(_ theme: CalloutTheme, scale: CGFloat) -> (NSFont, NSFont) {
        (NSFont.systemFont(ofSize: theme.titleSize * scale, weight: .bold),
         NSFont.systemFont(ofSize: theme.subtitleSize * scale, weight: .medium))
    }

    static func measure(_ c: Callout, theme: CalloutTheme,
                        outputSize: CGSize) -> CGSize {
        let scale = outputSize.height / 1080
        let (titleFont, subFont) = fonts(theme, scale: scale)
        let title = (c.text as NSString).size(withAttributes: [.font: titleFont])
        let sub = c.subtitle.map {
            ($0 as NSString).size(withAttributes: [.font: subFont])
        } ?? .zero

        let padX = 34 * scale, padY = 24 * scale
        let gap: CGFloat = c.subtitle == nil ? 0 : 8 * scale
        // Room for the accent bar on a lower third.
        let bar: CGFloat = c.style == "lowerThird" ? 18 * scale : 0
        return CGSize(width: ceil(max(title.width, sub.width) + padX * 2 + bar),
                      height: ceil(title.height + sub.height + gap + padY * 2))
    }

    static func draw(_ c: Callout, theme: CalloutTheme, size: CGSize,
                     outputHeight: CGFloat) -> CGImage? {
        let w = max(Int(size.width), 1), h = max(Int(size.height), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let scale = outputHeight / 1080
        func color(_ hex: String) -> CGColor {
            let v = Style.rgba(hex)
            return CGColor(red: CGFloat(v.x), green: CGFloat(v.y),
                           blue: CGFloat(v.z), alpha: CGFloat(v.w))
        }

        let radius = 14 * scale
        let box = CGRect(origin: .zero, size: size)
        ctx.setFillColor(color(theme.background))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
        ctx.fillPath()

        let bar: CGFloat = c.style == "lowerThird" ? 18 * scale : 0
        if bar > 0 {
            // Accent rail, clipped to the rounded left edge.
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius,
                               cornerHeight: radius, transform: nil))
            ctx.clip()
            ctx.setFillColor(color(c.accent ?? theme.accent))
            ctx.fill(CGRect(x: 0, y: 0, width: 6 * scale, height: size.height))
            ctx.restoreGState()
        }

        let (titleFont, subFont) = fonts(theme, scale: scale)
        let padX = 34 * scale + bar, padY = 24 * scale
        let gap: CGFloat = c.subtitle == nil ? 0 : 8 * scale

        let titleAttr = NSAttributedString(string: c.text, attributes: [
            .font: titleFont, .foregroundColor: NSColor(cgColor: color(theme.foreground))!,
        ])
        let titleLine = CTLineCreateWithAttributedString(titleAttr)
        var ta: CGFloat = 0, td: CGFloat = 0
        CTLineGetTypographicBounds(titleLine, &ta, &td, nil)

        var subHeight: CGFloat = 0
        var subLine: CTLine?
        if let s = c.subtitle {
            let attr = NSAttributedString(string: s, attributes: [
                .font: subFont,
                .foregroundColor: NSColor(cgColor: color(theme.subtitleForeground))!,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            var a: CGFloat = 0, d: CGFloat = 0
            CTLineGetTypographicBounds(line, &a, &d, nil)
            subHeight = a + d
            subLine = line
        }

        // CoreGraphics origin is bottom-left, so the subtitle is laid down
        // first and the title goes above it.
        var y = padY
        if let subLine {
            ctx.textPosition = CGPoint(x: padX, y: y)
            CTLineDraw(subLine, ctx)
            y += subHeight + gap
        }
        ctx.textPosition = CGPoint(x: padX, y: y + td)
        CTLineDraw(titleLine, ctx)

        return ctx.makeImage()
    }
}
