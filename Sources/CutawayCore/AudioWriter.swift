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
    private var notReady = 0
    private var appendFailures = 0
    /// Set once setup fails, so a broken track says so once instead of on
    /// every buffer for the length of the recording.
    private var broken = false
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// The input is built from the first sample's format description rather
    /// than a guess, because system audio and the microphone do not arrive in
    /// the same format.
    public func append(_ sb: CMSampleBuffer) {
        guard !broken, CMSampleBufferIsValid(sb),
              CMSampleBufferGetNumSamples(sb) > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        if !started {
            guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            let channels = Int(asbd?.mChannelsPerFrame ?? 2)
            let rate = asbd?.mSampleRate ?? 48000

            try? FileManager.default.removeItem(at: url)
            let w: AVAssetWriter
            do { w = try AVAssetWriter(outputURL: url, fileType: .m4a) }
            catch { fail("could not create \(url.lastPathComponent): \(error.localizedDescription)"); return }
            // No sourceFormatHint: with explicit AAC settings the hint has to
            // agree with them exactly, and a 16 kHz mono mic makes it refuse the
            // whole writer with "Cannot Encode Media".
            // The encoder wants a channel layout and one of its own sample
            // rates. A mic at 16 kHz mono without these fails the whole writer
            // with "Cannot Encode Media", and every buffer is then dropped.
            let out = min(channels, 2)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = out == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate >= 32000 ? rate : 44100,
                AVNumberOfChannelsKey: out,
                AVChannelLayoutKey: layoutData,
                AVEncoderBitRateKey: out > 1 ? 128_000 : 64_000,
            ])
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { fail("\(url.lastPathComponent): writer refused the audio input"); return }
            w.add(i)
            guard w.startWriting() else {
                fail("\(url.lastPathComponent) at \(Int(rate)) Hz, \(channels)ch: "
                     + (w.error?.localizedDescription ?? "could not start writing"))
                return
            }
            firstPTS = CMSampleBufferGetPresentationTimeStamp(sb)
            w.startSession(atSourceTime: firstPTS)
            writer = w
            input = i
            started = true
        }

        guard let input, input.isReadyForMoreMediaData else { notReady += 1; return }
        if !input.append(sb) { appendFailures += 1 }
        frames += 1
        lastPTS = CMSampleBufferGetPresentationTimeStamp(sb)
    }

    private func fail(_ message: String) {
        broken = true
        Log.line("ERROR: audio not recorded, \(message)")
    }

    public func finish(anchor: CMTime) async -> Manifest.Track? {
        lock.lock()
        let w = writer, i = input, ok = started
        lock.unlock()
        if notReady > 0 || appendFailures > 0 {
            Log.line("\(url.lastPathComponent): dropped \(notReady + appendFailures) of \(frames + notReady) buffers")
        }
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
