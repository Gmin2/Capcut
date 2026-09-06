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
    private let cursorPipeline: MTLRenderPipelineState
    private var cursorTexture: MTLTexture?
    private var keycastCache: (text: String, height: Int, texture: MTLTexture)?
    private var calloutCache: (id: String, texture: MTLTexture)?
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

        let cu = MTLRenderPipelineDescriptor()
        cu.vertexFunction = library.makeFunction(name: "cutaway_vertex")
        cu.fragmentFunction = library.makeFunction(name: "cutaway_cursor")
        let cAtt = cu.colorAttachments[0]!
        cAtt.pixelFormat = .bgra8Unorm
        cAtt.isBlendingEnabled = true
        cAtt.rgbBlendOperation = .add
        cAtt.alphaBlendOperation = .add
        cAtt.sourceRGBBlendFactor = .sourceAlpha
        cAtt.sourceAlphaBlendFactor = .sourceAlpha
        cAtt.destinationRGBBlendFactor = .oneMinusSourceAlpha
        cAtt.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        cursorPipeline = try device.makeRenderPipelineState(descriptor: cu)

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        if let cg = CursorImage.makeCGImage() {
            cursorTexture = try? makeTexture(from: cg)
        }
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

    /// Overlay texture for the keycast chip, redrawn only when the text or
    /// the output size changes. Drawing text is CPU work and would otherwise
    /// happen on every frame for a string that changes once a second.
    public func keycastTexture(text: String, size: CGSize, style: KeycastStyle,
                               outputHeight: CGFloat) -> MTLTexture? {
        let key = "\(text)|\(Int(size.width))x\(Int(size.height))"
        if let c = keycastCache, c.text == key, c.height == Int(outputHeight) {
            return c.texture
        }
        guard let img = KeycastRenderer.draw(text: text, size: size, style: style,
                                             outputHeight: outputHeight),
              let tex = try? makeTexture(from: img) else { return nil }
        keycastCache = (key, Int(outputHeight), tex)
        return tex
    }

    public func calloutTexture(_ c: Callout, id: String, size: CGSize,
                               theme: CalloutTheme, outputHeight: CGFloat) -> MTLTexture? {
        if let cache = calloutCache, cache.id == id { return cache.texture }
        guard let img = CalloutRenderer.draw(c, theme: theme, size: size,
                                             outputHeight: outputHeight),
              let tex = try? makeTexture(from: img) else { return nil }
        calloutCache = (id, tex)
        return tex
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
                     cursor: CursorParams? = nil,
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
        if let cursor, let tex = cursorTexture {
            var c = cursor
            enc.setRenderPipelineState(cursorPipeline)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentBytes(&c, length: MemoryLayout<CursorParams>.stride, index: 0)
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
                       cursor: CursorParams? = nil, into dst: CVPixelBuffer) -> Bool {
        guard let target = texture(from: dst) else { return false }
        return draw(background: background, layers: layers, cursor: cursor, into: target)
    }

    public func renderImage(background: BackgroundParams, layers: [Draw],
                            cursor: CursorParams? = nil, size: CGSize) throws -> CGImage {
        guard let target = makeTarget(width: Int(size.width), height: Int(size.height)),
              draw(background: background, layers: layers, cursor: cursor, into: target) else {
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
        float frameBar;
        float frameKind;
        float4 mask0;
        float4 mask1;
        float4 mask2;
        float4 mask3;
        float4 maskStrength;
    };

    struct CursorParams {
        float4 rect;
        float4 rippleColor;
        float2 outputSize;
        float2 ripplePos;
        float rippleRadius;
        float rippleAlpha;
        float opacity;
        float pad0;
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

        // With chrome, the video occupies the plate below the bar.
        float2 contentOrigin = P.dst.xy + float2(0.0, P.frameBar);
        float2 contentSize = P.dst.zw - float2(0.0, P.frameBar);
        float2 local = (p - contentOrigin) / max(contentSize, float2(1.0));
        float2 srcPx = P.src.xy + local * P.src.zw;

        // Masks are applied in source space, so a hidden region stays on the
        // thing it hides even while the camera zooms and pans over it.
        float4 masks[4] = { P.mask0, P.mask1, P.mask2, P.mask3 };
        float2 sampleAt = srcPx;
        float blurAmount = 0.0;
        for (int i = 0; i < 4; ++i) {
            float strength = P.maskStrength[i];
            if (strength == 0.0) { continue; }
            float4 m = masks[i];
            if (srcPx.x < m.x || srcPx.x > m.x + m.z ||
                srcPx.y < m.y || srcPx.y > m.y + m.w) { continue; }
            if (strength > 0.0) {
                // Mosaic: quantise the sample position to a grid.
                sampleAt = m.xy + (floor((srcPx - m.xy) / strength) + 0.5) * strength;
            } else {
                blurAmount = -strength;
            }
        }

        float3 c;
        if (blurAmount > 0.0) {
            // Cheap box blur. Enough to destroy text, which is the job.
            float3 acc = float3(0.0);
            float total = 0.0;
            for (int dy = -2; dy <= 2; ++dy) {
                for (int dx = -2; dx <= 2; ++dx) {
                    float2 o = float2(float(dx), float(dy)) * blurAmount * 0.5;
                    acc += src.sample(smp, (sampleAt + o) / P.sourceSize).rgb;
                    total += 1.0;
                }
            }
            c = acc / total;
        } else {
            c = src.sample(smp, sampleAt / P.sourceSize).rgb;
        }

        if (P.frameBar > 0.5) {
            float yInBar = p.y - P.dst.y;
            if (yInBar < P.frameBar) {
                // Faint vertical gradient, the way real title bars are lit.
                float g = yInBar / P.frameBar;
                float3 bar = P.frameKind > 1.5
                    ? mix(float3(0.161, 0.173, 0.192), float3(0.129, 0.141, 0.157), g)
                    : mix(float3(0.231, 0.239, 0.255), float3(0.184, 0.192, 0.208), g);
                c = bar;

                // Traffic lights, sized and spaced off the bar height so they
                // stay proportional at any zoom.
                float r = P.frameBar * 0.175;
                float cy = P.dst.y + P.frameBar * 0.5;
                float x0 = P.dst.x + P.frameBar * 0.62;
                float gap = P.frameBar * 0.56;
                float3 lights[3] = {
                    float3(0.996, 0.373, 0.345),
                    float3(0.996, 0.741, 0.176),
                    float3(0.157, 0.784, 0.251)
                };
                for (int i = 0; i < 3; ++i) {
                    float d = length(p - float2(x0 + gap * float(i), cy));
                    c = mix(c, lights[i], 1.0 - smoothstep(r - 1.0, r + 0.5, d));
                }

                if (P.frameKind > 1.5) {
                    // Address pill: a rounded bar centred in the chrome.
                    float pillH = P.frameBar * 0.52;
                    float2 pillC = float2(P.dst.x + P.dst.z * 0.5, cy);
                    float2 pillHalf = float2(P.dst.z * 0.32, pillH * 0.5);
                    float pd = sdRoundBox(p - pillC, pillHalf, pillH * 0.5);
                    c = mix(c, float3(0.086, 0.094, 0.11),
                            1.0 - smoothstep(-1.0, 0.5, pd));
                }

                // Hairline under the bar, which is what sells it as chrome
                // rather than a coloured rectangle.
                float edge = P.frameBar - yInBar;
                c = mix(c, float3(0.0), 0.35 * (1.0 - smoothstep(0.0, 1.5, edge)));
            }
        }

        if (P.borderWidth > 0.0) {
            float band = smoothstep(-P.borderWidth, 0.0, sd) * (1.0 - smoothstep(0.0, 1.5, sd));
            c = mix(c, P.borderColor.rgb, band * P.borderColor.a);
        }

        // plate over shadow, then the blend state puts that over the background
        float3 cOut = (c * aPlate) / max(aOut, 0.0001);
        return float4(cOut, aOut);
    }

    fragment float4 cutaway_cursor(VOut in [[stage_in]],
                                   texture2d<float> cur [[texture(0)]],
                                   constant CursorParams& P [[buffer(0)]]) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        float2 p = in.uv * P.outputSize;
        float4 acc = float4(0.0);

        // Click feedback: a soft disc with a brighter leading ring, expanding
        // and fading. Reads as a tap without stealing attention.
        if (P.rippleAlpha > 0.002) {
            float d = length(p - P.ripplePos);
            // A proper annulus: rises just inside the radius and falls at it.
            // The previous form evaluated to 1 everywhere inside, which filled
            // the whole disc instead of drawing a ring.
            float ring = smoothstep(P.rippleRadius - 10.0, P.rippleRadius - 5.0, d)
                       * (1.0 - smoothstep(P.rippleRadius - 2.0, P.rippleRadius + 1.0, d));
            float disc = 1.0 - smoothstep(0.0, P.rippleRadius, d);
            float a = clamp(max(ring, disc * 0.20), 0.0, 1.0)
                    * P.rippleAlpha * P.rippleColor.a;
            acc = float4(P.rippleColor.rgb, a);
        }

        float2 local = (p - P.rect.xy) / P.rect.zw;
        if (local.x >= 0.0 && local.x <= 1.0 && local.y >= 0.0 && local.y <= 1.0) {
            float4 c = cur.sample(smp, local);
            // CoreGraphics hands us premultiplied alpha; undo it so the straight
            // alpha blend state composites correctly.
            float3 rgb = c.a > 0.003 ? c.rgb / c.a : float3(1.0);
            float a = c.a * P.opacity;
            float aOut = a + acc.a * (1.0 - a);
            acc = float4((rgb * a + acc.rgb * acc.a * (1.0 - a)) / max(aOut, 0.0001), aOut);
        }

        if (acc.a < 0.003) { discard_fragment(); }
        return acc;
    }
    """
}
