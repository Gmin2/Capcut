import Foundation

public enum Log {
    /// Set by the UI so probe output lands in the window as well as stdout.
    nonisolated(unsafe) public static var sink: ((String) -> Void)?

    public static let path = NSString(string: "~/coding/tools/video-editor/tmp/claude/probe.txt")
        .expandingTildeInPath

    nonisolated(unsafe) private static var buffer = ""
    private static let lock = NSLock()

    public static func reset() {
        lock.lock(); buffer = ""; lock.unlock()
    }

    /// In CLI mode the log is diagnostics, so it goes to stderr and leaves
    /// stdout clean for the actual result.
    nonisolated(unsafe) public static var toStdout = false

    public static func line(_ s: String) {
        if toStdout {
            FileHandle.standardError.write(Data((s + "\n").utf8))
        } else {
            print(s)
        }
        sink?(s)
        guard !toStdout else { return }
        lock.lock(); buffer += s + "\n"; lock.unlock()
        write()
    }

    private static func write() {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        lock.lock(); let b = buffer; lock.unlock()
        try? b.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func flush() { write() }
}
