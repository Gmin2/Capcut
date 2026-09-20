import AppKit

/// Joining a run of captures of the same area into one tall picture.
///
/// Frames are matched on their rows rather than on scroll amounts: how far a
/// page actually moved is never exactly what the wheel asked for, and a fixed
/// guess leaves seams. Matching pixels has no such problem.
public enum Stitch {

    /// Rows of `b` that repeat the bottom of `a`. Nil when they do not overlap
    /// enough to be sure, which is the signal to start a new piece.
    public static func overlap(_ a: CGImage, _ b: CGImage, minimum: Double = 0.12) -> Int? {
        guard a.width == b.width, a.height > 8, b.height > 8 else { return nil }
        guard let rowsA = signature(a), let rowsB = signature(b) else { return nil }
        let height = rowsA.count
        let least = max(4, Int(Double(height) * minimum))

        var best = (shift: 0, score: Double.greatestFiniteMagnitude)
        // shift is how far b has scrolled past a
        for shift in 0...(height - least) {
            let count = height - shift
            var total = 0.0
            for i in 0..<count {
                let d = rowsA[shift + i] - rowsB[i]
                total += d * d
            }
            let score = total / Double(count)
            if score < best.score { best = (shift, score) }
        }
        // a perfect match is 0; anything this noisy is not the same content
        guard best.score < 90 else { return nil }
        return height - best.shift
    }

    /// One tall image from frames taken while scrolling down.
    public static func vertical(_ frames: [CGImage]) -> CGImage? {
        guard let first = frames.first else { return nil }
        guard frames.count > 1 else { return first }

        var pieces: [(image: CGImage, from: Int)] = [(first, 0)]
        var total = first.height
        var previous = first

        for frame in frames.dropFirst() {
            guard frame.width == first.width else { continue }
            let repeated = overlap(previous, frame) ?? 0
            let fresh = frame.height - repeated
            // nothing new on screen: the page did not move
            guard fresh > 2 else { continue }
            pieces.append((frame, repeated))
            total += fresh
            previous = frame
        }
        guard pieces.count > 1 else { return first }

        let width = first.width
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: total,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        var y = 0
        for (i, piece) in pieces.enumerated() {
            let keep = i == 0 ? piece.image : piece.image.cropping(
                to: CGRect(x: 0, y: piece.from, width: width, height: piece.image.height - piece.from))
            guard let keep else { continue }
            // the context is bottom-up, the page runs top-down
            ctx.cgContext.draw(keep, in: CGRect(x: 0, y: total - y - keep.height,
                                                width: width, height: keep.height))
            y += keep.height
        }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// One number per row: the mean brightness of a narrow strip, which is
    /// enough to line two frames up and cheap enough to do for every row.
    static func signature(_ image: CGImage) -> [Double]? {
        let width = 32
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rows = [Double](repeating: 0, count: height)
        for row in 0..<height {
            var sum = 0
            for x in 0..<width { sum += Int(pixels[row * width + x]) }
            // a bitmap context starts at the top row, which is reading order
            rows[row] = Double(sum) / Double(width)
        }
        return rows
    }
}
