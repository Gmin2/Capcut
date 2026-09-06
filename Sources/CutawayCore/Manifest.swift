import Foundation

/// What a recording session produced. Written once at the end of capture and
/// read by the editor and the export. Deliberately plain and self-describing so
/// an AI can reason about the recording without opening a video file.
public struct Manifest: Codable {
    public var version = 1
    public var screen: Track
    public var webcam: Track?
    public var mic: Track?
    public var systemAudio: Track?

    public struct Track: Codable {
        public var file: String
        public var pixelSize: [Double]
        /// Seconds after the screen recording's first frame that this track's
        /// first frame arrived. Tracks start at slightly different moments, so
        /// this is what keeps them in sync at render time.
        public var offset: Double
        public var duration: Double
        public var frames: Int
    }

    public static func load(from url: URL) -> Manifest? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Manifest.self, from: d)
        } catch {
            // A present-but-unreadable manifest is a different problem from an
            // absent one, and the difference matters when nothing plays.
            Log.line("recording.json is unreadable: \(error)")
            return nil
        }
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url)
    }
}
