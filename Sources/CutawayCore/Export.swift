import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

/// Pulls frames from one source track, holding the most recent one so a caller
/// stepping output time never gets a gap. Screen is 60fps and variable, the
/// camera is 30fps and starts a second late; both are handled the same way.
final class TrackReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: CMSampleBuffer?
    private var current: CMSampleBuffer?
    /// Global time minus this is the track's own time.
    let offset: Double
    let size: CGSize
    private(set) var held = 0

    init(url: URL, offset: Double) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "cutaway", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "no video track in \(url.lastPathComponent)"])
        }
        size = try await track.load(.naturalSize)
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        self.offset = offset
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "cutaway", code: 21)
        }
        pending = output.copyNextSampleBuffer()
    }

    /// Must be called with non-decreasing `t`; the reader only moves forward.
    func pixelBuffer(at t: Double) -> CVPixelBuffer? {
        let local = t - offset
        guard local >= 0 else { return nil }
        var advanced = false
        while let p = pending,
              CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(p)) <= local + 1e-9 {
            current = p
            pending = output.copyNextSampleBuffer()
            advanced = true
        }
        if !advanced { held += 1 }
        return current.flatMap { CMSampleBufferGetImageBuffer($0) }
    }
}

/// Constant-frame-rate export driven by our own clock, so animation is smooth
/// even while the screen is perfectly still.
public enum Export {

    public static func run(recordingDir: URL,
                           outputSize: CGSize = CGSize(width: 1920, height: 1080),
                           fps: Int32 = 60,
                           timeline: Timeline? = nil,
                           to url: URL) async throws {
        let manifest = Manifest.load(from: recordingDir.appendingPathComponent("recording.json"))
        let screenFile = manifest?.screen.file ?? "display.mov"

        let screen = try await TrackReader(
            url: recordingDir.appendingPathComponent(screenFile), offset: 0)
        var webcam: TrackReader?
        if let wc = manifest?.webcam {
            webcam = try? await TrackReader(
                url: recordingDir.appendingPathComponent(wc.file), offset: wc.offset)
        }
        let duration: Double
        if let d = manifest?.screen.duration {
            duration = d
        } else {
            let a = AVURLAsset(url: recordingDir.appendingPathComponent(screenFile))
            duration = CMTimeGetSeconds(try await a.load(.duration))
        }

        let tl = timeline ?? defaultTimeline(recordingDir: recordingDir,
                                             screenSize: screen.size,
                                             duration: duration,
                                             hasWebcam: webcam != nil)
        let state = RenderState(screenSize: screen.size, webcamSize: webcam?.size,
                                outputSize: outputSize, timeline: tl)
        let engine = try RenderEngine()

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let started = Date()
        let total = max(1, Int(duration * Double(fps)))
        var written = 0

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<total {
                    let t = Double(i) / Double(fps)
                    let f = state.evaluate(atSourceTime: t)

                    var layers: [RenderEngine.Draw] = []
                    if let sp = f.screen, let pb = screen.pixelBuffer(at: t),
                       let tex = engine.texture(from: pb) {
                        layers.append(.init(texture: tex, params: sp))
                    }
                    if let wp = f.webcam, let pb = webcam?.pixelBuffer(at: t),
                       let tex = engine.texture(from: pb) {
                        layers.append(.init(texture: tex, params: wp))
                    }

                    guard let pool = adaptor.pixelBufferPool else { continue }
                    var dst: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess,
                          let dst else { continue }
                    guard engine.render(background: f.background, layers: layers,
                                        into: dst) else { continue }

                    while !input.isReadyForMoreMediaData { usleep(500) }
                    if adaptor.append(dst, withPresentationTime:
                                        CMTime(value: CMTimeValue(i), timescale: fps)) {
                        written += 1
                    }
                }
                input.markAsFinished()
                cont.resume()
            }
        }
        await writer.finishWriting()

        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        Log.line("""
          export: \(written)/\(total) frames \(Int(outputSize.width))x\(Int(outputSize.height)) \
          @\(fps) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \
          \(String(format: "%.1f", Double(size) / 1_048_576)) MB, \
          webcam=\(webcam != nil ? "yes" : "no"), writer=\(writer.status.rawValue) \
          \(writer.error.map { "err=\($0.localizedDescription)" } ?? "")
          """)
    }

    static func defaultTimeline(recordingDir: URL, screenSize: CGSize,
                                duration: Double, hasWebcam: Bool) -> Timeline {
        var clicks: [(t: Double, p: CGPoint)] = []
        var cursor: [(t: Double, p: CGPoint)] = []
        if let d = try? Data(contentsOf: recordingDir.appendingPathComponent("events.json")),
           let ev = try? JSONDecoder().decode(EventRecorder.Events.self, from: d) {
            clicks = ev.clicks.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
            cursor = ev.cursor.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
        }
        let zooms = AutoZoom.generate(clicks: clicks, sourceSize: screenSize,
                                      duration: duration)
        let tl = Timeline(zooms: zooms, sourceSize: screenSize, cursor: cursor)

        // Open on the face, then hand over to the screen. This is the shape of
        // a pitch video; the editor will let you move the handover later.
        tl.scenes = hasWebcam
            ? [Scene(at: 0, layout: "talkingHead"),
               Scene(at: duration * 0.35, layout: "demo", transition: 0.8)]
            : [Scene(at: 0, layout: "screenOnly")]

        Log.line("timeline: \(zooms.count) zooms, \(tl.scenes.count) scenes " +
                 tl.scenes.map { String(format: "%@@%.2f", $0.layout, $0.at) }.joined(separator: " -> "))
        return tl
    }
}
