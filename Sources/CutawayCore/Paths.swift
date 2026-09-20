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

    /// A dated folder for a finished take, so recordings accumulate instead of
    /// overwriting each other. Named by time because that is how you actually
    /// look for one afterwards.
    public static func newRecording(named name: String? = nil) -> URL {
        let stamp: String
        if let name, !name.isEmpty {
            stamp = name
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            stamp = f.string(from: Date())
        }
        return recordingsRoot.appendingPathComponent(stamp)
    }

    /// Every recording on disk, newest first.
    public static func allRecordings() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return items.filter {
            // A recording is a real folder holding a manifest. Latest is a
            // symlink to one of these, so listing it too would show every
            // newest take twice.
            let isLink = (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink ?? false
            return !isLink
                && fm.fileExists(atPath: $0.appendingPathComponent("recording.json").path)
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a > b
        }
    }

    /// Stills live beside other pictures, not with the takes: a screenshot is
    /// a file you send, not a project you edit.
    public static var shotsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CUTAWAY_SHOTS"] {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        if let chosen = Prefs.saveFolder { return chosen }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Pictures").expandingTildeInPath)
        return pictures.appendingPathComponent("Cutaway")
    }

    public static func newShot() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = f.string(from: Date())
        let ext = Prefs.format.ext
        var url = shotsRoot.appendingPathComponent("Shot \(stamp).\(ext)")
        // two captures inside the same second must not overwrite each other
        var n = 2
        while FileManager.default.fileExists(atPath: url.path), n < 100 {
            url = shotsRoot.appendingPathComponent("Shot \(stamp) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    public static var support: URL {
        URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Cutaway")
            .expandingTildeInPath)
    }

    /// Points Latest at the newest take, so commands with no --in keep working
    /// while recordings accumulate under their own names.
    public static func linkLatest(to dir: URL) {
        let link = currentRecording
        guard dir != link else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: link)
        do {
            try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        } catch {
            Log.line("could not update Latest: \(error.localizedDescription)")
        }
    }

    public static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
