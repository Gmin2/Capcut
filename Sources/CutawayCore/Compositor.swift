import Foundation
import AVFoundation
import CoreVideo

/// Immutable snapshot the renderer reads. Published atomically on edit rather
/// than mutated, because AVFoundation calls the compositor concurrently.
public final class RenderState: @unchecked Sendable {
    public let screenSize: CGSize
    public let webcamSize: CGSize?
    public let outputSize: CGSize
    public let timeline: Timeline

    public init(screenSize: CGSize, webcamSize: CGSize?, outputSize: CGSize,
                timeline: Timeline) {
        self.screenSize = screenSize
        self.webcamSize = webcamSize
        self.outputSize = outputSize
        self.timeline = timeline
    }

    /// Pure: model plus time in, flat GPU numbers out. All animation logic is
    /// here, which keeps it unit testable and the shader dumb.
    public func evaluate(atSourceTime t: Double) -> FrameDescription {
        timeline.frame(at: t, screenSize: screenSize,
                       webcamSize: webcamSize, outputSize: outputSize)
    }
}

/// Used for the scrubbable preview. Export drives its own clock instead, since
/// AVAssetReaderVideoCompositionOutput emits one frame per source frame and
/// ignores frameDuration, which breaks animation on a static screen.
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
        guard let engine = Self.engine else {
            Self.lock.unlock()
            request.finish(with: NSError(domain: "cutaway", code: 11))
            return
        }

        let f = state.evaluate(atSourceTime: CMTimeGetSeconds(request.compositionTime))
        var layers: [RenderEngine.Draw] = []
        if let sp = f.screen, let tex = engine.texture(from: source) {
            layers.append(.init(texture: tex, params: sp))
        }
        let ok = engine.render(background: f.background, layers: layers, into: dst)
        Self.lock.unlock()

        if ok { request.finish(withComposedVideoFrame: dst) }
        else { request.finish(with: NSError(domain: "cutaway", code: 12)) }
    }
}
