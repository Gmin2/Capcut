import simd
import CoreGraphics

/// Field order must match the Metal structs exactly: float4s first so nothing
/// lands on a bad alignment boundary.

public struct BackgroundParams {
    public var bg0 = SIMD4<Float>()
    public var bg1 = SIMD4<Float>()
    public var outputSize = SIMD2<Float>()
    public var angle: Float = 0
    public var pad0: Float = 0
    public init() {}
}

/// One drawable layer: a rectangle of some source painted into a rectangle of
/// the output. Screen zoom animates `src`; a webcam shrinking to the corner
/// animates `dst`; reframing the camera animates `src` again. One mechanism,
/// which is why the whole feature set collapses into this struct.
public struct LayerParams {
    public var src = SIMD4<Float>()          // source pixels: x, y, w, h
    public var dst = SIMD4<Float>()          // output pixels: x, y, w, h
    public var borderColor = SIMD4<Float>()
    public var outputSize = SIMD2<Float>()
    public var sourceSize = SIMD2<Float>()
    public var shadowOffset = SIMD2<Float>()
    public var pad0 = SIMD2<Float>()
    public var cornerRadius: Float = 0
    public var shadowRadius: Float = 0
    public var shadowOpacity: Float = 0
    public var opacity: Float = 1
    public var borderWidth: Float = 0
    /// 1 makes the corner radius half the shorter side, giving a circle.
    public var circle: Float = 0
    /// Height of the chrome bar in output pixels; 0 for no frame.
    public var frameBar: Float = 0
    /// 0 none, 1 macOS window, 2 browser.
    public var frameKind: Float = 0
    /// Up to four masked regions in source pixels: x, y, w, h.
    public var mask0 = SIMD4<Float>()
    public var mask1 = SIMD4<Float>()
    public var mask2 = SIMD4<Float>()
    public var mask3 = SIMD4<Float>()
    /// Per-mask strength; 0 means unused. Negative means blur, positive mosaic.
    public var maskStrength = SIMD4<Float>()
    public init() {}
}
