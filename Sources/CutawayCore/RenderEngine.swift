import Foundation
import Metal
import MetalKit
import CoreGraphics
import CoreVideo

/// Multi-pass compositor: one pass fills the background, then one blended pass
/// per layer. Passes rather than a shader loop so the layer count is not baked
/// into the shader, and so adding captions or a keycast later costs nothing.
public final class RenderEngine {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let layerPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!

    public struct Draw {
        public let texture: MTLTexture
        public let params: LayerParams
        public init(texture: MTLTexture, params: LayerParams) {
            self.texture = texture
            self.params = params
        }
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw NSError(domain: "cutaway", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        self.device = device
        self.queue = queue

        let library = try device.makeLibrary(source: RenderEngine.shaderSource, options: nil)

        let bg = MTLRenderPipelineDescriptor()
        bg.vertexFunction = library.makeFunction(name: "cutaway_vertex")
        bg.fragmentFunction = library.makeFunction(name: "cutaway_background")
        bg.colorAttachments[0].pixelFormat = .bgra8Unorm
        backgroundPipeline = try device.makeRenderPipelineState(descriptor: bg)

        let ly = MTLRenderPipelineDescriptor()
        ly.vertexFunction = library.makeFunction(name: "cutaway_vertex")
        ly.fragmentFunction = library.makeFunction(name: "cutaway_layer")
        let att = ly.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .sourceAlpha
        att.sourceAlphaBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        layerPipeline = try device.makeRenderPipelineState(descriptor: ly)

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    public func texture(from pb: CVPixelBuffer) -> MTLTexture? {
        var out: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pb, nil,
                .bgra8Unorm, w, h, 0, &out) == kCVReturnSuccess,
              let out else { return nil }
        return CVMetalTextureGetTexture(out)
    }

    public func makeTexture(from image: CGImage) throws -> MTLTexture {
        try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ])
    }

    public func makeTarget(width: Int, height: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        return device.makeTexture(descriptor: td)
    }

    /// `present` is the on-screen drawable when rendering the live preview.
    /// Same command buffer, so the preview and the export differ only in where
    /// the pixels land.
    @discardableResult
    public func draw(background: BackgroundParams, layers: [Draw],
                     into target: MTLTexture,
                     present: (any MTLDrawable)? = nil) -> Bool {
        guard let cb = queue.makeCommandBuffer() else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var bg = background
        enc.setRenderPipelineState(backgroundPipeline)
        enc.setFragmentBytes(&bg, length: MemoryLayout<BackgroundParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Same encoder, so layers composite over the background without a
        // round trip to memory between passes.
        enc.setRenderPipelineState(layerPipeline)
        for layer in layers where layer.params.opacity > 0.001 {
            var p = layer.params
            enc.setFragmentTexture(layer.texture, index: 0)
            enc.setFragmentBytes(&p, length: MemoryLayout<LayerParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        if let present {
            cb.present(present)
            cb.commit()
        } else {
            cb.commit()
            cb.waitUntilCompleted()
        }
        return true
    }

    public func render(background: BackgroundParams, layers: [Draw],
                       into dst: CVPixelBuffer) -> Bool {
        guard let target = texture(from: dst) else { return false }
        return draw(background: background, layers: layers, into: target)
    }

    public func renderImage(background: BackgroundParams, layers: [Draw],
                            size: CGSize) throws -> CGImage {
        guard let target = makeTarget(width: Int(size.width), height: Int(size.height)),
              draw(background: background, layers: layers, into: target) else {
            throw NSError(domain: "cutaway", code: 4)
        }
        return try Self.cgImage(from: target)
    }

    private static func cgImage(from tex: MTLTexture) throws -> CGImage {
        let w = tex.width, h = tex.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        bytes.withUnsafeMutableBytes {
            tex.getBytes($0.baseAddress!, bytesPerRow: bpr,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8,
                                bitsPerPixel: 32, bytesPerRow: bpr,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue:
                                    CGImageAlphaInfo.premultipliedFirst.rawValue |
                                    CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)
        else { throw NSError(domain: "cutaway", code: 6) }
        return img
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BackgroundParams {
        float4 bg0;
        float4 bg1;
        float2 outputSize;
        float angle;
        float pad0;
    };

    struct LayerParams {
        float4 src;
        float4 dst;
        float4 borderColor;
        float2 outputSize;
        float2 sourceSize;
        float2 shadowOffset;
        float2 pad0;
        float cornerRadius;
        float shadowRadius;
        float shadowOpacity;
        float opacity;
        float borderWidth;
        float circle;
        float pad1; float pad2;
    };

    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut cutaway_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VOut o;
        o.pos = float4(p[vid], 0, 1);
        o.uv = p[vid] * float2(0.5, -0.5) + 0.5;
        return o;
    }

    static float sdRoundBox(float2 p, float2 b, float r) {
        r = min(r, min(b.x, b.y));
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    fragment float4 cutaway_background(VOut in [[stage_in]],
                                       constant BackgroundParams& P [[buffer(0)]]) {
        float a = P.angle * 3.14159265 / 180.0;
        float2 dir = float2(cos(a), sin(a));
        float t = clamp(dot(in.uv - 0.5, dir) + 0.5, 0.0, 1.0);
        return float4(mix(P.bg0.rgb, P.bg1.rgb, t), 1.0);
    }

    fragment float4 cutaway_layer(VOut in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  constant LayerParams& P [[buffer(0)]]) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        float2 p = in.uv * P.outputSize;

        float2 centre = P.dst.xy + P.dst.zw * 0.5;
        float2 halfSize = P.dst.zw * 0.5;
        // circle is a 0...1 blend, not a flag, so a rectangle rounding into a
        // circle mid-transition is continuous rather than a pop.
        float radius = mix(P.cornerRadius, min(halfSize.x, halfSize.y), saturate(P.circle));

        float sdSh = sdRoundBox(p - centre - P.shadowOffset, halfSize, radius);
        float aShadow = (1.0 - smoothstep(-P.shadowRadius, P.shadowRadius, sdSh))
                        * P.shadowOpacity * P.opacity;

        float sd = sdRoundBox(p - centre, halfSize, radius);
        float aPlate = (1.0 - smoothstep(-1.0, 1.0, sd)) * P.opacity;

        float aOut = aPlate + aShadow * (1.0 - aPlate);
        if (aOut < 0.002) { discard_fragment(); }

        float2 local = (p - P.dst.xy) / P.dst.zw;
        float2 srcPx = P.src.xy + local * P.src.zw;
        float3 c = src.sample(smp, srcPx / P.sourceSize).rgb;

        if (P.borderWidth > 0.0) {
            float band = smoothstep(-P.borderWidth, 0.0, sd) * (1.0 - smoothstep(0.0, 1.5, sd));
            c = mix(c, P.borderColor.rgb, band * P.borderColor.a);
        }

        // plate over shadow, then the blend state puts that over the background
        float3 cOut = (c * aPlate) / max(aOut, 0.0001);
        return float4(cOut, aOut);
    }
    """
}
