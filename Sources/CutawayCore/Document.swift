import Foundation
import AppKit

/// A recording as a single file in Finder.
///
/// The pieces are the same ones the loose-directory layout uses, so nothing
/// about the renderer changes; a `.cutaway` package is just a directory macOS
/// presents as one item. That keeps project.json hand-editable, which the whole
/// scripted-editing story depends on.
public enum Document {

    public static let fileExtension = "cutaway"

    /// Marks a directory as a package so Finder shows it as a single file.
    public static func makePackage(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // A package is a directory with the bundle bit set. No plist needed for
        // a document type we own.
        try (url as NSURL).setResourceValue(true, forKey: .isPackageKey)
    }

    public static func isDocument(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Where the media lives inside a document. Loose directories are still
    /// supported, so the CLI works either way.
    public static func mediaDirectory(for url: URL) -> URL {
        isDocument(url) ? url : url
    }

    /// Moves a loose recording directory into a document, leaving the original
    /// alone. Returns the new document URL.
    @discardableResult
    public static func wrap(recordingDir: URL, as name: String,
                            in parent: URL) throws -> URL {
        let doc = parent.appendingPathComponent(name)
            .appendingPathExtension(fileExtension)
        try? FileManager.default.removeItem(at: doc)
        try FileManager.default.copyItem(at: recordingDir, to: doc)
        try (doc as NSURL).setResourceValue(true, forKey: .isPackageKey)
        return doc
    }

    /// Everything a finished recording contains, for reporting and for cleanup.
    public struct Contents {
        public var screen: URL?
        public var webcam: URL?
        public var mic: URL?
        public var system: URL?
        public var events: URL?
        public var transcript: URL?
        public var project: URL?
        public var totalBytes: Int
    }

    public static func inspect(_ url: URL) -> Contents {
        let fm = FileManager.default
        func exists(_ name: String) -> URL? {
            let u = url.appendingPathComponent(name)
            return fm.fileExists(atPath: u.path) ? u : nil
        }
        var total = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return Contents(screen: exists("display.mov"), webcam: exists("webcam.mov"),
                        mic: exists("mic.m4a"), system: exists("system.m4a"),
                        events: exists("events.json"),
                        transcript: exists("transcript.json"),
                        project: exists(Project.filename), totalBytes: total)
    }

    /// Deletes the raw media, keeping the edit and the event log. Raw capture is
    /// the bulk of the size and is only needed until the export is approved.
    @discardableResult
    public static func discardMedia(in url: URL) throws -> Int {
        let c = inspect(url)
        var freed = 0
        for f in [c.screen, c.webcam, c.mic, c.system].compactMap({ $0 }) {
            freed += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: f)
        }
        return freed
    }
}
