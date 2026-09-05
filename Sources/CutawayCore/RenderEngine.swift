import Foundation
import Metal
import MetalKit
import CoreGraphics
import CoreVideo

/// One Metal pass turns a source frame into a finished output frame. Preview
/// and export both go through here, which is the only way to guarantee what you
/// see is what you get.
public final class RenderEngine {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "cutaway", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "cutaway", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "no command queue"])
        }
        self.queue = queue

        // Compiled at runtime rather than shipped as a metallib: SwiftPM has no
        // Metal build step, and the cost is a few ms once at startup.
        let library = try device.makeLibrary(source: RenderEngine.shaderSource,
                                             options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "cutaway_vertex")
        desc.fragmentFunction = library.makeFunction(name: "cutaway_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Wraps a CVPixelBuffer as a Metal texture with no copy. This is the path
    /// AVFoundation uses; the CGImage one below is only for stills.
    public func texture(from pb: CVPixelBuffer) -> MTLTexture? {
        var out: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pb, nil,
                .bgra8Unorm, w, h, 0, &out) == kCVReturnSuccess,
              let out else { return nil }
        return CVMetalTextureGetTexture(out)
    }

    /// Renders straight into a destination pixel buffer, which is what the
    /// compositor needs. Same shader as the still path, so preview, export and
    /// thumbnails can never drift apart.
    public func render(source: CVPixelBuffer, into dst: CVPixelBuffer,
                       params: RenderParams) -> Bool {
        guard let srcTex = texture(from: source),
              let dstTex = texture(from: dst) else { return false }
        return draw(source: srcTex, target: dstTex, params: params)
    }

    @discardableResult
    private func draw(source: MTLTexture, target: MTLTexture,
                      params: RenderParams) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var p = params
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentBytes(&p, length: MemoryLayout<RenderParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return true
    }

    public func makeTexture(from image: CGImage) throws -> MTLTexture {
        try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ])
    }

    public func render(source: MTLTexture, params: RenderParams) throws -> CGImage {
        let w = Int(params.outputSize.x), h = Int(params.outputSize.y)

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = device.makeTexture(descriptor: td) else {
            throw NSError(domain: "cutaway", code: 4)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            throw NSError(domain: "cutaway", code: 5)
        }
        var p = params
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentBytes(&p, length: MemoryLayout<RenderParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

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

    struct Params {
        float4 crop;
        float4 plate;
        float4 bg0;
        float4 bg1;
        float4 borderColor;
        float2 outputSize;
        float2 sourceSize;
        float2 shadowOffset;
        float2 pad0;
        float cornerRadius;
        float shadowRadius;
        float shadowOpacity;
        float bgAngle;
        float borderWidth;
        float pad1; float pad2; float pad3;
    };

    struct VOut { float4 pos [[position]]; float2 uv; };

    // Full-screen triangle, no vertex buffer needed.
    vertex VOut cutaway_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VOut o;
        o.pos = float4(p[vid], 0, 1);
        o.uv = p[vid] * float2(0.5, -0.5) + 0.5;
        return o;
    }

    static float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    fragment float4 cutaway_fragment(VOut in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     constant Params& P [[buffer(0)]]) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        float2 p = in.uv * P.outputSize;

        float a = P.bgAngle * 3.14159265 / 180.0;
        float2 dir = float2(cos(a), sin(a));
        float t = clamp(dot(in.uv - 0.5, dir) + 0.5, 0.0, 1.0);
        float3 col = mix(P.bg0.rgb, P.bg1.rgb, t);

        float2 centre = P.plate.xy + P.plate.zw * 0.5;
        float2 halfSize = P.plate.zw * 0.5;

        float sdShadow = sdRoundBox(p - centre - P.shadowOffset, halfSize, P.cornerRadius);
        float shadow = 1.0 - smoothstep(-P.shadowRadius, P.shadowRadius, sdShadow);
        col = mix(col, float3(0.0), shadow * P.shadowOpacity);

        float sd = sdRoundBox(p - centre, halfSize, P.cornerRadius);
        float inside = 1.0 - smoothstep(-1.0, 1.0, sd);
        if (inside > 0.0) {
            float2 local = (p - P.plate.xy) / P.plate.zw;
            float2 srcPx = P.crop.xy + local * P.crop.zw;
            float3 sc = src.sample(smp, srcPx / P.sourceSize).rgb;
            col = mix(col, sc, inside);
        }

        if (P.borderWidth > 0.0) {
            float band = smoothstep(-P.borderWidth, 0.0, sd) * (1.0 - smoothstep(0.0, 1.5, sd));
            col = mix(col, P.borderColor.rgb, band * P.borderColor.a);
        }
        return float4(col, 1.0);
    }
    """
}
