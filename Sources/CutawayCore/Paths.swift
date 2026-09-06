import Foundation

/// Where Cutaway keeps things.
///
/// Recordings go in ~/Movies/Cutaway because that is where a Mac user expects
/// video, and it needs no permission beyond the ones we already hold. Overridable
/// so a script can put a project anywhere without arguing with the default.
public enum Paths {

    public static var recordingsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CUTAWAY_HOME"] {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Movies").expandingTildeInPath)
        return movies.appendingPathComponent("Cutaway")
    }

    /// The working recording, used when no directory is given.
    public static var currentRecording: URL {
        recordingsRoot.appendingPathComponent("Latest")
    }

    public static var support: URL {
        URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Cutaway")
            .expandingTildeInPath)
    }

    public static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
