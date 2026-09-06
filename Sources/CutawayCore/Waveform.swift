import Foundation
import AVFoundation
import AppKit

/// Peak envelope of an audio track, for drawing in the timeline.
///
/// Finding the sentence you want by scrubbing is slow; seeing where you spoke
/// makes it immediate. Peaks rather than RMS because speech onsets are what you
/// are looking for, and RMS smooths exactly those away.
public enum Waveform {

    /// One peak per bucket, normalised to 0...1.
    public static func peaks(from url: URL, buckets: Int = 900) async -> [Float] {
        guard let samples = try? await AudioMix.decodeMono(
                url, format: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 44100, channels: 1,
                                           interleaved: false)!),
              !samples.isEmpty else { return [] }

        let per = max(1, samples.count / buckets)
        var out: [Float] = []
        out.reserveCapacity(buckets)
        var i = 0
        while i < samples.count {
            var peak: Float = 0
            let end = min(i + per, samples.count)
            for j in i..<end { peak = max(peak, abs(samples[j])) }
            out.append(peak)
            i = end
        }

        // Normalise to the loudest moment, so a quietly recorded take still
        // fills the lane instead of being a flat line.
        let loudest = out.max() ?? 1
        guard loudest > 0.0001 else { return out }
        return out.map { min($0 / loudest, 1) }
    }

    /// Which audio track to draw, preferring the voice.
    public static func preferredTrack(in dir: URL, manifest: Manifest?) -> URL? {
        for name in [manifest?.mic?.file, manifest?.systemAudio?.file,
                     "voiceover.m4a", "mix.m4a"] {
            guard let name else { continue }
            let u = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}
