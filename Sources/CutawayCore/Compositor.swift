import Foundation
import AVFoundation
import CoreVideo

/// Immutable snapshot the compositor reads. Published atomically on edit rather
/// than mutated, because AVFoundation calls the compositor concurrently on its
/// own queues.
public final class RenderState: @unchecked Sendable {
    public let style: Style
    public let sourceSize: CGSize
    public let outputSize: CGSize

    public init(style: Style, sourceSize: CGSize, outputSize: CGSize) {
        self.style = style
        self.sourceSize = sourceSize
        self.outputSize = outputSize
    }

    /// Pure: model plus time in, flat numbers out. All animation logic will live
    /// here, which keeps it unit testable and keeps the shader dumb.
    public func evaluate(atSourceTime t: Double) -> RenderParams {
        let crop = CGRect(origin: .zero, size: sourceSize)   // zoom lands here
        return style.params(outputSize: outputSize, sourceSize: sourceSize, crop: crop)
    }
}

/// One instruction spans the whole asset and the compositor computes everything
/// from `compositionTime`. The alternative, an instruction per keyframe, would
/// mean thousands of objects for continuously animated properties.
public final class CutawayCompositor: NSObject, AVVideoCompositing {

    nonisolated(unsafe) public static var state: RenderState?
    nonisolated(unsafe) private static var engine: RenderEngine?
    private static let lock = NSLock()

    public var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    public func renderContextChanged(_ context: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let state = Self.state,
              let trackID = request.sourceTrackIDs.first?.int32Value,
              let source = request.sourceFrame(byTrackID: trackID),
              let dst = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "cutaway", code: 10))
            return
        }

        Self.lock.lock()
        if Self.engine == nil { Self.engine = try? RenderEngine() }
        let engine = Self.engine
        Self.lock.unlock()

        guard let engine else {
            request.finish(with: NSError(domain: "cutaway", code: 11))
            return
        }

        let params = state.evaluate(
            atSourceTime: CMTimeGetSeconds(request.compositionTime))

        Self.lock.lock()
        let ok = engine.render(source: source, into: dst, params: params)
        Self.lock.unlock()

        if ok { request.finish(withComposedVideoFrame: dst) }
        else { request.finish(with: NSError(domain: "cutaway", code: 12)) }
    }
}
