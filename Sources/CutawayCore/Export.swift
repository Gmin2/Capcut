import Foundation
import AVFoundation
import CoreVideo

/// Constant-frame-rate export driven by our own clock.
///
/// AVAssetReaderVideoCompositionOutput emits one frame per *source* frame and
/// ignores the composition's frameDuration, which is fine for a passthrough but
/// wrong the moment anything is animated: a zoom needs a fresh frame every
/// 1/60 even while the screen is perfectly still. So we step output time
/// ourselves and hold the most recent source frame across gaps. That also gives
/// us the exact timing control cuts and speed ramps will need.
///
/// The renderer and the parameter evaluation are the same ones the preview
/// uses, so what you see is still what you get.
public enum Export {

    static func loadTimeline(besides mov: URL, sourceSize: CGSize,
                             duration: Double) -> Timeline? {
        let url = mov.deletingLastPathComponent().appendingPathComponent("events.json")
        guard let data = try? Data(contentsOf: url),
              let ev = try? JSONDecoder().decode(EventRecorder.Events.self, from: data)
        else { return nil }

        let clicks = ev.clicks.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
        let cursor = ev.cursor.map { (t: $0.t, p: CGPoint(x: $0.x, y: $0.y)) }
        let zooms = AutoZoom.generate(clicks: clicks, sourceSize: sourceSize,
                                      duration: duration)
        Log.line("auto-zoom: \(zooms.count) from \(clicks.count) clicks " +
                 zooms.map { String(format: "[%.2f-%.2f x%.2f]", $0.start, $0.end, $0.level) }
                      .joined(separator: " "))
        return Timeline(zooms: zooms, sourceSize: sourceSize, cursor: cursor)
    }

    public static func run(mov: URL,
                           style: Style = .default,
                           outputSize: CGSize = CGSize(width: 1920, height: 1080),
                           fps: Int32 = 60,
                           to url: URL) async throws {
        let asset = AVURLAsset(url: mov)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "cutaway", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "no video track"])
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let sourceSize = try await track.load(.naturalSize)

        // Events live next to the recording. Without them we still export,
        // just with no zooms.
        let timeline = loadTimeline(besides: mov, sourceSize: sourceSize, duration: duration)
        let state = RenderState(style: style, sourceSize: sourceSize,
                                outputSize: outputSize, timeline: timeline)
        let engine = try RenderEngine()

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

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

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "cutaway", code: 21)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let started = Date()
        let total = max(1, Int(duration * Double(fps)))
        var written = 0, held = 0

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // The frame currently on screen. Kept as a sample buffer, not a
                // bare pixel buffer, because the pixel buffer is owned by it.
                var current: CMSampleBuffer?
                var pending = readerOutput.copyNextSampleBuffer()

                for i in 0..<total {
                    let t = Double(i) / Double(fps)

                    while let p = pending,
                          CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(p)) <= t + 1e-9 {
                        current = p
                        pending = readerOutput.copyNextSampleBuffer()
                    }
                    guard let cur = current,
                          let src = CMSampleBufferGetImageBuffer(cur),
                          let pool = adaptor.pixelBufferPool else { continue }
                    if pending == nil { held += 1 }

                    var dst: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess,
                          let dst else { continue }

                    guard engine.render(source: src, into: dst,
                                        params: state.evaluate(atSourceTime: t)) else { continue }

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
          writer=\(writer.status.rawValue) \
          \(writer.error.map { "err=\($0.localizedDescription)" } ?? "")
          """)
    }
}
