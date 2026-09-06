import Foundation
import AppKit
import CoreGraphics
import CoreText

/// Burned-in subtitles, built from the transcript we already record.
///
/// Most demo videos are watched on mute, so captions do more for reach than any
/// visual effect. The words and their timings already exist in transcript.json,
/// so this is presentation only.
public struct CaptionStyle: Codable {
    public var enabled = false
    /// Words shown at once. Two or three lands better than a full sentence:
    /// long enough to read as a phrase, short enough to stay in sync.
    public var wordsPerCue = 4
    public var fontSize: Double = 46
    public var foreground = "#FFFFFF"
    public var background = "#0B0F14D9"
    /// Highlights the word being spoken, the way social captions do.
    public var highlightSpoken = true
    public var highlight = "#FFD166"
    /// Fraction of the output height from the bottom.
    public var bottomMargin: Double = 0.09
    public var maxWidth: Double = 0.8
    public var cornerRadius: Double = 12

    public init() {}
}

/// One line of caption with the word to emphasise.
struct Cue {
    let start: Double
    let end: Double
    let words: [(text: String, start: Double, end: Double)]

    var text: String { words.map(\.text).joined(separator: " ") }
}

public enum CaptionRenderer {

    /// Groups transcript words into short cues. Splits on a real pause as well
    /// as on length, so a cue never straddles a gap in speech.
    static func cues(from transcript: Transcript, style: CaptionStyle) -> [Cue] {
        let words = transcript.segments.filter { !$0.text.isEmpty }
        guard !words.isEmpty else { return [] }

        var out: [Cue] = []
        var buffer: [(text: String, start: Double, end: Double)] = []

        func flush() {
            guard let first = buffer.first, let last = buffer.last else { return }
            out.append(Cue(start: first.start,
                           // Held a beat past the last word so it is readable.
                           end: last.end + 0.35,
                           words: buffer))
            buffer = []
        }

        for (i, w) in words.enumerated() {
            buffer.append((w.text, w.t, w.t + w.duration))
            let gapToNext = i + 1 < words.count ? words[i + 1].t - (w.t + w.duration) : 0
            let endsSentence = w.text.hasSuffix(".") || w.text.hasSuffix("?")
                || w.text.hasSuffix("!")
            if buffer.count >= style.wordsPerCue || endsSentence || gapToNext > 0.6 {
                flush()
            }
        }
        flush()
        return out
    }

    /// The cue visible at a moment, and which of its words is being spoken.
    static func active(_ cues: [Cue], at t: Double)
        -> (cue: Cue, spokenIndex: Int)? {
        guard let cue = cues.first(where: { t >= $0.start && t <= $0.end }) else { return nil }
        let index = cue.words.lastIndex { t >= $0.start } ?? 0
        return (cue, index)
    }

    static func measure(_ cue: Cue, style: CaptionStyle,
                        outputSize: CGSize) -> CGSize {
        let scale = outputSize.height / 1080
        let font = NSFont.systemFont(ofSize: style.fontSize * scale, weight: .bold)
        let size = (cue.text as NSString).size(withAttributes: [.font: font])
        let padX = 26 * scale, padY = 14 * scale
        return CGSize(width: min(ceil(size.width + padX * 2),
                                 outputSize.width * style.maxWidth),
                      height: ceil(size.height + padY * 2))
    }

    static func draw(_ cue: Cue, spokenIndex: Int, style: CaptionStyle,
                     size: CGSize, outputHeight: CGFloat) -> CGImage? {
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

        let radius = style.cornerRadius * scale
        ctx.setFillColor(color(style.background))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        // One attributed string with the spoken word coloured, so spacing and
        // kerning stay correct rather than drawing word by word.
        let font = NSFont.systemFont(ofSize: style.fontSize * scale, weight: .bold)
        let attributed = NSMutableAttributedString()
        for (i, word) in cue.words.enumerated() {
            let spoken = style.highlightSpoken && i == spokenIndex
            attributed.append(NSAttributedString(
                string: i == 0 ? word.text : " " + word.text,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor(cgColor:
                        color(spoken ? style.highlight : style.foreground))!,
                ]))
        }

        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.textPosition = CGPoint(x: (size.width - CGFloat(width)) / 2,
                                   y: (size.height - (ascent + descent)) / 2 + descent)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}
