import Foundation
import AppKit
import CoreGraphics
import CoreText
import simd

/// The keystroke overlay.
public struct KeycastStyle: Codable {
    public var visible = true
    /// "bottomCenter", "bottomLeft", "bottomRight", "topCenter".
    public var position = "bottomCenter"
    /// How long a chip stays on screen after its last keystroke.
    public var holdFor: Double = 1.6
    public var fadeOut: Double = 0.35
    /// Typing merges into one chip until this long a pause.
    public var mergeWindow: Double = 0.9
    public var maxChips = 4
    public var fontSize: Double = 34
    public var background = "#12161CE6"
    public var foreground = "#F2F5F8"
    public var margin: Double = 0.055

    public init() {}
}

public struct KeycastParams {
    public var rect = SIMD4<Float>()
    public var outputSize = SIMD2<Float>()
    public var opacity: Float = 1
    public var pad0: Float = 0
    public init() {}
}

/// One visible chip: a chord like ⌘⇧P, or a run of typing merged into a word.
struct KeyChip {
    var start: Double
    var end: Double
    var text: String
}

enum KeycastBuilder {

    /// Groups raw keystrokes into chips. Typing merges into words; chords stay
    /// separate, because "⌘S" is the interesting event and "s" is not.
    static func chips(from keys: [EventRecorder.Key], style: KeycastStyle) -> [KeyChip] {
        var out: [KeyChip] = []
        for k in keys.sorted(by: { $0.t < $1.t }) {
            if k.isText, var last = out.last, last.textIsPlain,
               k.t - last.end < style.mergeWindow {
                last.text += k.label
                last.end = k.t
                out[out.count - 1] = last
                continue
            }
            out.append(KeyChip(start: k.t, end: k.t, text: k.label))
        }
        return out
    }
}

extension KeyChip {
    /// Typed runs merge, chords never do. A chord always contains a modifier
    /// glyph, so that is the test.
    var textIsPlain: Bool {
        !text.contains(where: { "⌘⌥⌃⇧".contains($0) })
            && !["return", "tab", "space", "delete", "esc"].contains(text)
    }
}

/// Draws the overlay with CoreText into a bitmap, which is then uploaded as a
/// texture. A glyph atlas would be faster, but this only redraws when the
/// visible text changes, so it never shows up in a frame budget.
public enum KeycastRenderer {

    public struct Frame {
        public let image: CGImage
        public let params: KeycastParams
    }

    /// - Returns: nil when nothing should be shown at this moment.
    static func frame(chips: [KeyChip], at t: Double, style: KeycastStyle,
                      outputSize: CGSize) -> (text: String, opacity: Double,
                                              size: CGSize, origin: CGPoint)? {
        guard style.visible else { return nil }
        let live = chips.filter { t >= $0.start && t <= $0.end + style.holdFor }
        guard !live.isEmpty else { return nil }

        let shown = live.suffix(style.maxChips)
        let text = shown.map(\.text).joined(separator: "  ")

        // Fade on the newest chip, so a run of keys does not flicker.
        let newest = shown.last!
        let age = t - (newest.end + style.holdFor - style.fadeOut)
        let opacity = age <= 0 ? 1 : max(0, 1 - age / max(style.fadeOut, 0.01))

        let scale = outputSize.height / 1080.0
        let font = NSFont.monospacedSystemFont(ofSize: style.fontSize * scale,
                                               weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attrs)
        let padX = 26 * scale, padY = 14 * scale
        let size = CGSize(width: ceil(measured.width + padX * 2),
                          height: ceil(measured.height + padY * 2))

        let margin = style.margin * outputSize.height
        var origin = CGPoint.zero
        switch style.position {
        case "bottomLeft":
            origin = CGPoint(x: margin, y: outputSize.height - size.height - margin)
        case "bottomRight":
            origin = CGPoint(x: outputSize.width - size.width - margin,
                             y: outputSize.height - size.height - margin)
        case "topCenter":
            origin = CGPoint(x: (outputSize.width - size.width) / 2, y: margin)
        default:
            origin = CGPoint(x: (outputSize.width - size.width) / 2,
                             y: outputSize.height - size.height - margin)
        }
        return (text, opacity, size, origin)
    }

    static func draw(text: String, size: CGSize, style: KeycastStyle,
                     outputHeight: CGFloat) -> CGImage? {
        let w = max(Int(size.width), 1), h = max(Int(size.height), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let scale = outputHeight / 1080.0
        let radius = min(size.height / 2, 20 * scale)
        let box = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

        let bg = Style.rgba(style.background)
        ctx.setFillColor(CGColor(red: CGFloat(bg.x), green: CGFloat(bg.y),
                                 blue: CGFloat(bg.z), alpha: CGFloat(bg.w)))
        ctx.addPath(path)
        ctx.fillPath()

        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(1.5 * scale)
        ctx.addPath(path)
        ctx.strokePath()

        let fg = Style.rgba(style.foreground)
        let font = NSFont.monospacedSystemFont(ofSize: style.fontSize * scale,
                                               weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(red: CGFloat(fg.x), green: CGFloat(fg.y),
                                      blue: CGFloat(fg.z), alpha: CGFloat(fg.w)),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (size.width - CGFloat(textWidth)) / 2,
                                   y: (size.height - (ascent + descent)) / 2 + descent)
        CTLineDraw(line, ctx)

        return ctx.makeImage()
    }
}
