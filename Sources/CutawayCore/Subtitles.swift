import Foundation

/// A subtitle file for the exported video.
///
/// The transcript is in source time, and the export is in edited time, so
/// every word is mapped through the same time map the video uses. Words that
/// were cut out simply have no output time, and drop out of the file.
public enum Subtitles {

    /// One line of a subtitle file.
    public struct Line {
        public var start: Double
        public var end: Double
        public var text: String
    }

    /// Groups words into short lines, the way captions are read: a few words
    /// at a time, broken at a pause or a full stop.
    public static func lines(from transcript: Transcript, timeMap: TimeMap,
                             wordsPerLine: Int = 7, gap: Double = 0.6) -> [Line] {
        var out: [Line] = []
        var current: [String] = []
        var start = 0.0
        var end = 0.0
        var previousSourceEnd: Double?

        func flush() {
            guard !current.isEmpty, end > start else {
                current = []
                return
            }
            out.append(Line(start: start, end: end, text: current.joined(separator: " ")))
            current = []
        }

        for word in transcript.segments.sorted(by: { $0.t < $1.t }) {
            let middle = word.t + word.duration / 2
            // a word that was cut out has no place in the file
            guard timeMap.segments.contains(where: { middle >= $0.sourceStart && middle <= $0.sourceEnd })
            else {
                flush()
                previousSourceEnd = nil
                continue
            }
            guard let a = timeMap.outputTime(forSource: word.t) else {
                flush()
                previousSourceEnd = nil
                continue
            }
            let b = timeMap.outputTime(forSource: word.t + word.duration) ?? (a + word.duration)

            let brokeForPause = previousSourceEnd.map { word.t - $0 > gap } ?? false
            if current.isEmpty {
                start = a
            } else if current.count >= wordsPerLine || brokeForPause {
                flush()
                start = a
            }
            current.append(word.text)
            end = max(b, a + 0.2)
            previousSourceEnd = word.t + word.duration

            if word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") {
                flush()
            }
        }
        flush()
        return out.sorted { $0.start < $1.start }
    }

    /// SubRip, which every player and every upload form understands.
    public static func srt(_ lines: [Line]) -> String {
        lines.enumerated().map { i, line in
            "\(i + 1)\n\(stamp(line.start)) --> \(stamp(max(line.end, line.start + 0.3)))\n\(line.text)\n"
        }.joined(separator: "\n")
    }

    static func stamp(_ t: Double) -> String {
        let total = max(0, t)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        let millis = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    /// Writes the file next to the video, and says how many lines it holds.
    @discardableResult
    public static func write(recordingDir: URL, timeMap: TimeMap, beside video: URL,
                             wordsPerLine: Int = 7) -> Int {
        guard let transcript = Transcript.load(from: recordingDir), !transcript.segments.isEmpty
        else { return 0 }
        let made = lines(from: transcript, timeMap: timeMap, wordsPerLine: wordsPerLine)
        guard !made.isEmpty else { return 0 }
        let url = video.deletingPathExtension().appendingPathExtension("srt")
        do {
            try srt(made).write(to: url, atomically: true, encoding: .utf8)
            Log.line("subtitles: \(made.count) lines -> \(url.lastPathComponent)")
            return made.count
        } catch {
            Log.line("ERROR: could not write subtitles, \(error.localizedDescription)")
            return 0
        }
    }
}
