import simd

/// Flat, plain-old-data description of one output frame. Everything animated
/// resolves to this before it reaches the GPU, so all timing and easing logic
/// lives in one testable place and the shader stays dumb.
///
/// Field order matters: it must match the Metal struct exactly, float4s first
/// so nothing lands on a bad alignment boundary.
public struct RenderParams {
    public var crop        = SIMD4<Float>()   // source pixels: x, y, w, h
    public var plate       = SIMD4<Float>()   // output pixels: x, y, w, h
    public var bg0         = SIMD4<Float>()
    public var bg1         = SIMD4<Float>()
    public var borderColor = SIMD4<Float>()
    public var outputSize  = SIMD2<Float>()
    public var sourceSize  = SIMD2<Float>()
    public var shadowOffset = SIMD2<Float>()
    public var pad0        = SIMD2<Float>()
    public var cornerRadius: Float = 0
    public var shadowRadius: Float = 0
    public var shadowOpacity: Float = 0
    public var bgAngle: Float = 0
    public var borderWidth: Float = 0
    public var pad1: Float = 0
    public var pad2: Float = 0
    public var pad3: Float = 0

    public init() {}
}
