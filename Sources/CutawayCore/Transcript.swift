import Foundation
import Speech

/// What was said, and exactly when.
///
/// Paired with events.json this is a complete textual description of a
/// recording: an editor, human or otherwise, can decide every cut and zoom
/// without decoding a single video frame. That is the whole reason the capture
/// layer bothers to log anything.
public struct Transcript: Codable {
    public var version = 1
    public var text: String = ""
    public var segments: [Segment] = []

    public struct Segment: Codable {
        /// Start in source time, already shifted by the mic track's offset.
        public var t: Double
        public var duration: Double
        public var text: String
        public var confidence: Double
    }

    public static func load(from dir: URL) -> Transcript? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: d)
    }

    public func write(to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: dir.appendingPathComponent("transcript.json"))
    }

    /// Words grouped into rough sentences, which is a more useful unit than
    /// segments when deciding where a scene should change.
    public func sentences() -> [Segment] {
        var out: [Segment] = []
        var buf: [Segment] = []
        for s in segments {
            buf.append(s)
            let ends = s.text.hasSuffix(".") || s.text.hasSuffix("?") || s.text.hasSuffix("!")
            let gapNext = buf.count >= 14
            if ends || gapNext {
                out.append(merge(buf)); buf = []
            }
        }
        if !buf.isEmpty { out.append(merge(buf)) }
        return out
    }

    private func merge(_ xs: [Segment]) -> Segment {
        let start = xs.first?.t ?? 0
        let end = (xs.last?.t ?? 0) + (xs.last?.duration ?? 0)
        return Segment(t: start, duration: end - start,
                       text: xs.map(\.text).joined(separator: " "),
                       confidence: xs.map(\.confidence).reduce(0, +) / Double(max(xs.count, 1)))
    }
}

public enum Transcriber {

    public static func requestAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// - Parameter offset: where this audio file starts relative to the screen
    ///   recording, so segment times come out in source time.
    public static func run(audio: URL, offset: Double) async throws -> Transcript {
        guard await requestAccess() else {
            throw NSError(domain: "cutaway", code: 70,
                          userInfo: [NSLocalizedDescriptionKey: "speech recognition not authorised"])
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw NSError(domain: "cutaway", code: 71,
                          userInfo: [NSLocalizedDescriptionKey: "recognizer unavailable"])
        }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        // On-device keeps the recording off Apple's servers, which matters for
        // a tool pointed at your own screen.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Domain words a general recogniser reliably mangles ("Jason" for
        // JSON, "cut away" for Cutaway). Cheap and noticeably effective.
        request.contextualStrings = [
            "Cutaway", "JSON", "macOS", "Swift", "Metal", "keyframe", "timeline",
            "zoom", "webcam", "screen recorder", "repo", "API", "SDK", "UI",
            "Claude", "AI", "demo", "hackathon",
        ]

        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { cont in
            var done = false
            recognizer.recognitionTask(with: request) { res, err in
                guard !done else { return }
                if let err { done = true; cont.resume(throwing: err); return }
                guard let res, res.isFinal else { return }
                done = true
                cont.resume(returning: res)
            }
        }

        var t = Transcript()
        t.text = result.bestTranscription.formattedString
        t.segments = result.bestTranscription.segments.map {
            Transcript.Segment(t: $0.timestamp + offset,
                               duration: $0.duration,
                               text: $0.substring,
                               confidence: Double($0.confidence))
        }
        Log.line("transcript: \(t.segments.count) segments, on-device=\(request.requiresOnDeviceRecognition)")
        if !t.text.isEmpty {
            Log.line("  \"\(t.text.prefix(160))\"")
        }
        return t
    }
}
