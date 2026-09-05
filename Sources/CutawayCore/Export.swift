import Foundation
import AVFoundation

/// Reader -> composition -> writer, rather than AVAssetExportSession, so we get
/// real progress, cancellation and bitrate control. Crucially it uses the same
/// AVVideoComposition the preview will, so the two cannot drift.
public enum Export {

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
        let duration = try await asset.load(.duration)
        let natural = try await track.load(.naturalSize)

        CutawayCompositor.state = RenderState(
            style: style, sourceSize: natural, outputSize: outputSize)

        let comp = AVMutableVideoComposition()
        comp.customVideoCompositorClass = CutawayCompositor.self
        comp.renderSize = outputSize
        comp.frameDuration = CMTime(value: 1, timescale: fps)

        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: duration)
        inst.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: track)]
        comp.instructions = [inst]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output.videoComposition = comp
        output.alwaysCopiesSampleData = false
        reader.add(output)

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
        writer.add(input)

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "cutaway", code: 21)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let started = Date()
        var written = 0
        let queue = DispatchQueue(label: "com.mintu.cutaway.export")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let sb = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    input.append(sb)
                    written += 1
                }
            }
        }
        await writer.finishWriting()

        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        Log.line("""
          export: \(written) frames \(Int(outputSize.width))x\(Int(outputSize.height)) \
          in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \
          \(String(format: "%.1f", Double(size) / 1_048_576)) MB, \
          reader=\(reader.status.rawValue) writer=\(writer.status.rawValue) \
          \(writer.error.map { "err=\($0.localizedDescription)" } ?? "")
          """)
    }
}
