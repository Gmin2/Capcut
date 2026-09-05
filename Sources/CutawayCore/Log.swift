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

    public static func line(_ s: String) {
        print(s)
        sink?(s)
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
