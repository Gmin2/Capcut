import Foundation
import AVFoundation

/// Writes one audio stream to its own file. Separate files rather than extra
/// tracks on the video writer, because feeding a writer's audio input out of
/// step with its video input makes it stall waiting to interleave.
public final class AudioWriter {

    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var firstPTS = CMTime.zero
    private var lastPTS = CMTime.zero
    private(set) public var frames = 0
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// The input is built from the first sample's format description rather
    /// than a guess, because system audio and the microphone do not arrive in
    /// the same format.
    public func append(_ sb: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sb),
              CMSampleBufferGetNumSamples(sb) > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        if !started {
            guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            let channels = Int(asbd?.mChannelsPerFrame ?? 2)
            let rate = asbd?.mSampleRate ?? 48000

            try? FileManager.default.removeItem(at: url)
            guard let w = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return }
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: min(channels, 2),
                AVEncoderBitRateKey: 128_000,
            ], sourceFormatHint: format)
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { return }
            w.add(i)
            guard w.startWriting() else { return }
            firstPTS = CMSampleBufferGetPresentationTimeStamp(sb)
            w.startSession(atSourceTime: firstPTS)
            writer = w
            input = i
            started = true
        }

        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sb)
        frames += 1
        lastPTS = CMSampleBufferGetPresentationTimeStamp(sb)
    }

    public func finish(anchor: CMTime) async -> Manifest.Track? {
        lock.lock()
        let w = writer, i = input, ok = started
        lock.unlock()
        guard ok, let w, let i else { return nil }
        i.markAsFinished()
        await w.finishWriting()
        guard w.status == .completed else {
            Log.line("audio \(url.lastPathComponent) failed: \(w.error?.localizedDescription ?? "?")")
            return nil
        }
        return Manifest.Track(file: url.lastPathComponent,
                              pixelSize: [0, 0],
                              offset: CMTimeGetSeconds(firstPTS - anchor),
                              duration: CMTimeGetSeconds(lastPTS - firstPTS),
                              frames: frames)
    }
}
