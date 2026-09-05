import Foundation
import AVFoundation

/// Narration, described as text on a timeline rather than recorded.
///
/// Pairs with the rest of project.json: an AI that can read events.json already
/// knows what happened and when, so it can write both the edit and the words
/// describing it. You record silently and the video narrates itself.
public struct Voiceover: Codable {
    /// "system" uses the on-device speech synthesiser: free, offline, no key.
    public var engine: String = "system"
    /// A voice identifier from `AVSpeechSynthesisVoice`, or nil for the default.
    /// Premium voices sound markedly better and are worth installing.
    public var voice: String?
    /// 0...1, where AVSpeechUtteranceDefaultSpeechRate is 0.5.
    public var rate: Double = 0.48
    public var pitch: Double = 1.0
    public var volume: Double = 1.0
    public var lines: [Line] = []

    public struct Line: Codable {
        /// Source time this line starts speaking.
        public var at: Double
        public var text: String
        /// Overrides the top-level voice for this line.
        public var voice: String?
        public init(at: Double, text: String, voice: String? = nil) {
            self.at = at
            self.text = text
            self.voice = voice
        }
    }

    public init() {}
}

/// Reference box so the audio callback and the watchdog see the same list.
private final class ChunkBox: @unchecked Sendable {
    var chunks: [AVAudioPCMBuffer] = []
}

public enum VoiceoverRenderer {

    /// Canonical mixing format. Everything is converted into this before being
    /// laid onto the master buffer, because the synthesiser's native format
    /// varies by voice.
    static let sampleRate = 44100.0

    public static func availableVoices() -> [(name: String, identifier: String, quality: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .map { v in
                let q: String
                switch v.quality {
                case .premium: q = "premium"
                case .enhanced: q = "enhanced"
                default: q = "default"
                }
                return (v.name, v.identifier, q)
            }
    }

    /// Renders every line onto one silent bed of `duration` seconds and writes
    /// an m4a. Lines that would run past the end are kept; the caller decides
    /// whether to extend the video or trim.
    public static func render(_ vo: Voiceover, duration: Double, to url: URL) async throws -> Double {
        guard !vo.lines.isEmpty else { return 0 }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw NSError(domain: "cutaway", code: 50)
        }

        var spoken: [(at: Double, buffer: AVAudioPCMBuffer)] = []
        for line in vo.lines {
            if let b = try await speak(line, vo: vo, into: format) {
                spoken.append((line.at, b))
            }
        }
        guard !spoken.isEmpty else { return 0 }

        let tail = spoken.map { $0.at + Double($0.buffer.frameLength) / sampleRate }.max() ?? 0
        let total = max(duration, tail)
        let frames = AVAudioFrameCount(total * sampleRate)
        guard let master = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "cutaway", code: 51)
        }
        master.frameLength = frames
        guard let dst = master.floatChannelData?[0] else {
            throw NSError(domain: "cutaway", code: 52)
        }
        memset(dst, 0, Int(frames) * MemoryLayout<Float>.size)

        for (at, buf) in spoken {
            guard let src = buf.floatChannelData?[0] else { continue }
            let start = Int(max(0, at) * sampleRate)
            let n = min(Int(buf.frameLength), Int(frames) - start)
            guard n > 0 else { continue }
            // Additive so overlapping lines mix rather than clobber.
            for i in 0..<n { dst[start + i] += src[i] }
        }

        // Cheap peak limiter: TTS plus overlap can clip, and clipping in a
        // pitch video sounds like a broken recording.
        var peak: Float = 0
        for i in 0..<Int(frames) { peak = max(peak, abs(dst[i])) }
        if peak > 0.98 {
            let g = 0.98 / peak
            for i in 0..<Int(frames) { dst[i] *= g }
        }

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        try file.write(from: master)

        Log.line(String(format: "voiceover: %d lines, %.2fs, -> %@",
                        spoken.count, total, url.lastPathComponent))
        return total
    }

    private static func speak(_ line: Voiceover.Line, vo: Voiceover,
                              into format: AVAudioFormat) async throws -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: line.text)
        if let id = line.voice ?? vo.voice, let v = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = v
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = Float(vo.rate)
        utterance.pitchMultiplier = Float(vo.pitch)
        utterance.volume = Float(vo.volume)

        // Held outside the closure on purpose. Created inside, it is released
        // as soon as the closure returns, the callback never fires and the
        // continuation deadlocks the whole export.
        let synth = AVSpeechSynthesizer()
        let box = ChunkBox()

        let chunks: [AVAudioPCMBuffer] = await withCheckedContinuation { cont in
            var finished = false
            let resumeOnce: ([AVAudioPCMBuffer]) -> Void = { result in
                guard !finished else { return }
                finished = true
                cont.resume(returning: result)
            }
            // Watchdog: a voice that never emits its terminating empty buffer
            // must not be able to hang an export forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                resumeOnce(box.chunks)
            }
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    resumeOnce(box.chunks)
                    return
                }
                if let copy = AVAudioPCMBuffer(pcmFormat: pcm.format,
                                               frameCapacity: pcm.frameLength) {
                    copy.frameLength = pcm.frameLength
                    let bytes = Int(pcm.frameLength) * Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
                    memcpy(copy.mutableAudioBufferList.pointee.mBuffers.mData,
                           pcm.audioBufferList.pointee.mBuffers.mData, bytes)
                    box.chunks.append(copy)
                }
            }
        }
        withExtendedLifetime(synth) {}
        guard let first = chunks.first else { return nil }

        let totalFrames = chunks.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0,
              let joined = AVAudioPCMBuffer(pcmFormat: first.format,
                                            frameCapacity: AVAudioFrameCount(totalFrames))
        else { return nil }
        joined.frameLength = AVAudioFrameCount(totalFrames)

        let bpf = Int(first.format.streamDescription.pointee.mBytesPerFrame)
        var offset = 0
        for c in chunks {
            memcpy(joined.mutableAudioBufferList.pointee.mBuffers.mData!.advanced(by: offset * bpf),
                   c.audioBufferList.pointee.mBuffers.mData, Int(c.frameLength) * bpf)
            offset += Int(c.frameLength)
        }

        if joined.format == format { return joined }
        guard let converter = AVAudioConverter(from: joined.format, to: format) else { return nil }
        let ratio = format.sampleRate / joined.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(joined.frameLength) * ratio + 4096)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else {
            return nil
        }
        var done = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return joined
        }
        if let error { throw error }
        return out
    }
}
