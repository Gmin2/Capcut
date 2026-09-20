import Foundation
import CoreGraphics
import simd

/// Where one source sits on the canvas. Rects are normalised to the output so
/// a layout is resolution independent.
/// Chrome drawn around a layer: nothing, a macOS title bar with traffic
/// lights, a browser bar with an address pill, or a phone bezel with a camera
/// hole. Drawn in the shader rather than as a bitmap so it stays sharp at any
/// zoom and any output size.
public enum DeviceFrame: String, Codable {
    case none, macWindow, browser, phone
}

public struct Placement: Codable {
    /// x, y, w, h in 0...1 of the output frame.
    public var rect: [Double]
    /// "contain" keeps the source aspect inside `rect`; "fill" covers it and
    /// crops the overflow, which is what a fullscreen webcam wants.
    public var fit: String = "contain"
    public var circle: Bool = false
    public var cornerRadius: Double = 18
    public var opacity: Double = 1
    public var shadowOpacity: Double = 0.55
    public var shadowRadius: Double = 70
    public var shadowOffsetY: Double = 26
    public var borderWidth: Double = 1.5
    public var borderColor: String = "#FFFFFF26"
    public var frame: DeviceFrame = .none
    /// Title bar height in output pixels at 1080p, scaled with the output.
    public var frameBarHeight: Double = 34

    public init(rect: [Double], fit: String = "contain", circle: Bool = false,
                cornerRadius: Double = 18, opacity: Double = 1) {
        self.rect = rect
        self.fit = fit
        self.circle = circle
        self.cornerRadius = cornerRadius
        self.opacity = opacity
    }

    /// Every field but the rect is optional, so a layout written by hand in
    /// project.json only has to say what differs from the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        rect = try c.decode([Double].self, forKey: .rect)
        fit = get(.fit, "contain")
        circle = get(.circle, false)
        cornerRadius = get(.cornerRadius, 18)
        opacity = get(.opacity, 1)
        shadowOpacity = get(.shadowOpacity, 0.55)
        shadowRadius = get(.shadowRadius, 70)
        shadowOffsetY = get(.shadowOffsetY, 26)
        borderWidth = get(.borderWidth, 1.5)
        borderColor = get(.borderColor, "#FFFFFF26")
        frame = get(.frame, DeviceFrame.none)
        frameBarHeight = get(.frameBarHeight, 34)
    }
}

/// A named arrangement of the sources. Scenes reference these by name so the
/// timeline reads as intent ("talkingHead then demo") rather than as numbers.
public struct Layout: Codable {
    public var screen: Placement?
    public var webcam: Placement?

    public static let talkingHead = Layout(
        screen: nil,
        webcam: Placement(rect: [0, 0, 1, 1], fit: "fill", cornerRadius: 0))

    public static let demo = Layout(
        screen: Placement(rect: [0.055, 0.055, 0.89, 0.89]),
        webcam: Placement(rect: [0.74, 0.66, 0.20, 0.28], fit: "fill",
                          circle: true))

    public static let sideBySide = Layout(
        screen: Placement(rect: [0.02, 0.14, 0.63, 0.72]),
        webcam: Placement(rect: [0.67, 0.22, 0.31, 0.56], fit: "fill",
                          cornerRadius: 24))

    public static let screenOnly = Layout(
        screen: Placement(rect: [0.055, 0.055, 0.89, 0.89]),
        webcam: nil)

    public static let named: [String: Layout] = [
        "talkingHead": .talkingHead,
        "demo": .demo,
        "sideBySide": .sideBySide,
        "screenOnly": .screenOnly,
    ]
}

/// A cut from one layout to another at a moment in source time.
public struct Scene: Codable {
    public var at: Double
    public var layout: String
    public var transition: Double = 0.6

    public init(at: Double, layout: String, transition: Double = 0.6) {
        self.at = at
        self.layout = layout
        self.transition = transition
    }

    // transition is optional in the file: without this, one scene written
    // without it fails to decode and every scene is silently dropped
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Double.self, forKey: .at)
        layout = try c.decode(String.self, forKey: .layout)
        transition = try c.decodeIfPresent(Double.self, forKey: .transition) ?? 0.6
    }
}

extension Placement {
    /// Resolve to concrete output pixels. Done per layout before interpolating,
    /// so animating between "fill" and "contain" is just a lerp of two rects
    /// rather than a special case in the shader.
    func layerParams(sourceSize: CGSize, outputSize: CGSize) -> LayerParams {
        var p = LayerParams()
        var box = CGRect(x: rect[0] * outputSize.width,
                         y: rect[1] * outputSize.height,
                         width: rect[2] * outputSize.width,
                         height: rect[3] * outputSize.height)

        // A circle needs a square destination, or the rounded-box SDF gives a
        // pill instead. Fit the largest centred square inside the box.
        if circle {
            let side = min(box.width, box.height)
            box = CGRect(x: box.midX - side / 2, y: box.midY - side / 2,
                         width: side, height: side)
        }

        let sourceAspect = sourceSize.width / sourceSize.height
        var dst = box
        var src = CGRect(origin: .zero, size: sourceSize)

        if fit == "contain" {
            var w = box.width, h = w / sourceAspect
            if h > box.height { h = box.height; w = h * sourceAspect }
            dst = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        } else {
            // Cover the box and crop the overflow out of the source instead.
            let boxAspect = box.width / box.height
            if sourceAspect > boxAspect {
                let w = sourceSize.height * boxAspect
                src = CGRect(x: (sourceSize.width - w) / 2, y: 0,
                             width: w, height: sourceSize.height)
            } else {
                let h = sourceSize.width / boxAspect
                src = CGRect(x: 0, y: (sourceSize.height - h) / 2,
                             width: sourceSize.width, height: h)
            }
        }

        p.src = SIMD4(Float(src.origin.x), Float(src.origin.y),
                      Float(src.width), Float(src.height))
        p.dst = SIMD4(Float(dst.origin.x), Float(dst.origin.y),
                      Float(dst.width), Float(dst.height))
        p.sourceSize = SIMD2(Float(sourceSize.width), Float(sourceSize.height))
        p.outputSize = SIMD2(Float(outputSize.width), Float(outputSize.height))
        p.cornerRadius = Float(cornerRadius)
        p.circle = circle ? 1 : 0
        p.opacity = Float(opacity)
        p.shadowOpacity = Float(shadowOpacity)
        p.shadowRadius = Float(shadowRadius)
        p.shadowOffset = SIMD2(0, Float(shadowOffsetY))
        p.borderWidth = Float(borderWidth)
        p.borderColor = Style.rgba(borderColor)

        if frame == .phone {
            // The bezel wraps the screen on every side, so the plate grows
            // outward by it and the corners round off with it. Sized off the
            // screen width because that is what a real phone's bezel follows.
            let bezel = p.dst.z * Placement.phoneBezel
            p.dst = SIMD4(p.dst.x - bezel, p.dst.y - bezel, p.dst.z + bezel * 2, p.dst.w + bezel * 2)
            p.cornerRadius += bezel
            p.frameBar = bezel
            p.frameKind = 3
        } else if frame != .none {
            // The bar sits above the content, so the plate grows upward and the
            // video itself is not squashed.
            let bar = Float(frameBarHeight) * Float(outputSize.height / 1080)
            p.dst = SIMD4(p.dst.x, p.dst.y - bar, p.dst.z, p.dst.w + bar)
            p.frameBar = bar
            p.frameKind = frame == .macWindow ? 1 : 2
        }
        return p
    }

    /// Bezel thickness as a share of the screen width.
    static let phoneBezel: Float = 0.032

    /// A hidden layer still needs a position, or it would fly in from (0,0)
    /// during a transition. Collapsing to the centre of where it will be reads
    /// as a scale-in instead.
    static func hidden(like other: LayerParams) -> LayerParams {
        var p = other
        p.opacity = 0
        let cx = other.dst.x + other.dst.z / 2
        let cy = other.dst.y + other.dst.w / 2
        p.dst = SIMD4(cx, cy, 0.0001, 0.0001)
        return p
    }
}

func mix(_ a: LayerParams, _ b: LayerParams, _ t: Float) -> LayerParams {
    func l(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
    var o = b
    o.src = a.src + (b.src - a.src) * t
    o.dst = a.dst + (b.dst - a.dst) * t
    o.cornerRadius = l(a.cornerRadius, b.cornerRadius)
    o.opacity = l(a.opacity, b.opacity)
    o.shadowOpacity = l(a.shadowOpacity, b.shadowOpacity)
    o.shadowRadius = l(a.shadowRadius, b.shadowRadius)
    o.shadowOffset = a.shadowOffset + (b.shadowOffset - a.shadowOffset) * t
    o.borderWidth = l(a.borderWidth, b.borderWidth)
    o.circle = l(a.circle, b.circle)
    return o
}
