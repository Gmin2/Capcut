import Foundation
import AVFoundation

/// How the recorded and synthesised audio are balanced.
public struct AudioSettings: Codable {
    public var mic: Double = 1.0
    public var system: Double = 0.55
    public var voiceover: Double = 1.0
    /// Drops system audio while narration is playing, so music or a video
    /// playing on screen does not fight the voice.
    public var duckSystemUnderVoice = true
    public var duckAmount: Double = 0.25
    public init() {}
}

/// Mixes every audio source into one track that matches the edited timeline.
///
/// The tricky part is not the mixing, it is the cuts: audio is recorded in
/// source time, but the video the viewer sees has spans removed and sped up.
/// So each kept segment is copied separately, and sped-up spans are resampled
/// rather than played back fast, which would chipmunk the voice.
public enum AudioMix {

    static let sampleRate = 44100.0

    struct Source {
        let url: URL
        /// Where this file starts relative to the screen recording.
        let offset: Double
        let gain: Double
        /// Voiceover is already authored against the edited timeline, so it
        /// must not be put through the cut map a second time.
        let inEditedTime: Bool
    }

    /// - Returns: the mixed file, or nil when there was nothing to mix.
    public static func build(recordingDir: URL, manifest: Manifest,
                             timeMap: TimeMap, settings: AudioSettings,
                             voiceover: URL?, outputDuration: Double,
                             to url: URL) async throws -> URL? {
        var sources: [Source] = []
        if let m = manifest.mic, m.duration > 0.05, settings.mic > 0.001 {
            sources.append(Source(url: recordingDir.appendingPathComponent(m.file),
                                  offset: m.offset, gain: settings.mic,
                                  inEditedTime: false))
        }
        if let s = manifest.systemAudio, s.duration > 0.05, settings.system > 0.001 {
            sources.append(Source(url: recordingDir.appendingPathComponent(s.file),
                                  offset: s.offset, gain: settings.system,
                                  inEditedTime: false))
        }
        if let v = voiceover, settings.voiceover > 0.001 {
            sources.append(Source(url: v, offset: 0, gain: settings.voiceover,
                                  inEditedTime: true))
        }
        guard !sources.isEmpty else { return nil }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let master = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(outputDuration, 0.1) * sampleRate + 4096))
        else { throw NSError(domain: "cutaway", code: 80) }

        master.frameLength = AVAudioFrameCount(max(outputDuration, 0.1) * sampleRate)
        guard let dst = master.floatChannelData?[0] else {
            throw NSError(domain: "cutaway", code: 81)
        }
        memset(dst, 0, Int(master.frameLength) * MemoryLayout<Float>.size)

        var voiceEnergy: [Float]?
        var mixedAny = false

        for src in sources {
            guard let mono = try? await decodeMono(src.url, format: format) else { continue }
            let isVoice = src.inEditedTime

            if isVoice {
                // Already in edited time: lay it straight down.
                add(mono, into: dst, at: 0, length: Int(master.frameLength),
                    gain: Float(src.gain))
                voiceEnergy = envelope(mono, frames: Int(master.frameLength))
            } else {
                // Source time: walk the kept segments, resampling sped-up ones.
                var outFrame = 0
                for seg in timeMap.segments where seg.sourceDuration > 0.001 {
                    let outFrames = Int(seg.outputDuration * sampleRate)
                    defer { outFrame += outFrames }
                    guard outFrames > 0 else { continue }

                    let startFrame = Int((seg.sourceStart - src.offset) * sampleRate)
                    let srcFrames = Int(seg.sourceDuration * sampleRate)
                    guard startFrame >= 0 || startFrame + srcFrames > 0 else { continue }
                    let lo = max(0, startFrame)
                    let hi = min(mono.count, startFrame + srcFrames)
                    guard hi > lo else { continue }
                    let slice = Array(mono[lo..<hi])

                    // Speed changes are time-stretched, not resampled. Simply
                    // stepping through the samples faster raises the pitch,
                    // which turns a sped-up explanation into chipmunks.
                    let written = seg.speed > 1.01
                        ? (timeStretch(slice, rate: seg.speed, format: format) ?? [])
                        : slice
                    add(written, into: dst, at: outFrame,
                        length: Int(master.frameLength), gain: Float(src.gain))
                }
            }
            mixedAny = true
        }
        guard mixedAny else { return nil }

        // Duck system audio under narration. Applied after mixing for
        // simplicity: the envelope is dominated by the voice anyway.
        if settings.duckSystemUnderVoice, let env = voiceEnergy,
           manifest.systemAudio != nil {
            let floorGain = Float(settings.duckAmount)
            for i in 0..<min(Int(master.frameLength), env.count) {
                let speaking = min(env[i] * 8, 1)
                // Lerp the whole bus between unity and the duck floor.
                dst[i] *= 1 - speaking * (1 - floorGain)
            }
        }

        limit(dst, frames: Int(master.frameLength))

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 160_000,
        ])
        try file.write(from: master)
        Log.line(String(format: "audio mix: %d sources, %.2fs -> %@",
                        sources.count, outputDuration, url.lastPathComponent))
        return url
    }

    /// Plays `src` back `rate` times faster while holding pitch, using the
    /// system's time-pitch unit offline.
    static func timeStretch(_ src: [Float], rate: Double,
                            format: AVAudioFormat) -> [Float]? {
        guard !src.isEmpty, rate > 1.01 else { return src }
        guard let input = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(src.count)),
              let channel = input.floatChannelData?[0] else { return nil }
        input.frameLength = AVAudioFrameCount(src.count)
        src.withUnsafeBufferPointer {
            channel.update(from: $0.baseAddress!, count: src.count)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let unit = AVAudioUnitTimePitch()
        unit.rate = Float(min(max(rate, 1.0 / 32), 32))
        engine.attach(player)
        engine.attach(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)

        let outFrames = AVAudioFrameCount(Double(src.count) / rate + 4096)
        do {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: 4096)
            try engine.start()
            player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
            player.play()
        } catch {
            Log.line("time stretch unavailable: \(error.localizedDescription)")
            return nil
        }
        defer { engine.stop(); engine.disableManualRenderingMode() }

        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount) else { return nil }

        var out: [Float] = []
        out.reserveCapacity(Int(outFrames))
        while out.count < Int(outFrames) {
            let want = min(AVAudioFrameCount(Int(outFrames) - out.count),
                           scratch.frameCapacity)
            guard let status = try? engine.renderOffline(want, to: scratch) else { break }
            guard status == .success, scratch.frameLength > 0,
                  let data = scratch.floatChannelData?[0] else { break }
            out.append(contentsOf: UnsafeBufferPointer(start: data,
                                                       count: Int(scratch.frameLength)))
        }
        return out
    }

    private static func add(_ src: [Float], into dst: UnsafeMutablePointer<Float>,
                            at offset: Int, length: Int, gain: Float) {
        guard gain != 0 else { return }
        let n = min(src.count, length - offset)
        guard n > 0, offset >= 0 else { return }
        for i in 0..<n { dst[offset + i] += src[i] * gain }
    }

    /// Rough loudness envelope, used for ducking.
    private static func envelope(_ src: [Float], frames: Int) -> [Float] {
        var env = [Float](repeating: 0, count: frames)
        let window = Int(sampleRate * 0.05)
        var acc: Float = 0
        for i in 0..<min(frames, src.count) {
            acc += (abs(src[i]) - acc) / Float(max(window, 1))
            env[i] = acc
        }
        return env
    }

    private static func limit(_ dst: UnsafeMutablePointer<Float>, frames: Int) {
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(dst[i])) }
        guard peak > 0.98 else { return }
        let g = 0.98 / peak
        for i in 0..<frames { dst[i] *= g }
    }

    /// Decodes any audio file to a flat mono float array at the mix rate.
    static func decodeMono(_ url: URL, format: AVAudioFormat) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }

        var out: [Float] = []
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { fp in
                out.append(contentsOf: UnsafeBufferPointer(start: fp, count: count))
            }
        }
        return out
    }
}
