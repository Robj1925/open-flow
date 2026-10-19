import Foundation

/// Append-only timeline of a dictation, for diagnosing "it feels slow".
/// Each line carries the wall-clock time and the milliseconds since the
/// last `begin()` (the hotkey press). Lives at
/// `~/Library/Logs/OpenFlow/timing.log`, truncated when it passes 256 KB.
public final class TimingLog {
    public static let shared = TimingLog()
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/OpenFlow/timing.log")

    private static let maxBytes = 256 * 1024
    private let queue = DispatchQueue(label: "dev.openflow.timing-log", qos: .utility)
    private let lock = NSLock()
    private var origin = Date()
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Marks the start of a new timeline (hotkey down).
    public func begin(_ label: String) {
        lock.lock()
        origin = Date()
        lock.unlock()
        note("---- \(label)")
    }

    /// Records one event. Safe from any thread; the write is off-thread.
    public func note(_ event: String) {
        let now = Date()
        lock.lock()
        let elapsed = now.timeIntervalSince(origin)
        lock.unlock()
        let line = "\(clock.string(from: now))  +\(Int(elapsed * 1000)) ms  \(event)\n"
        queue.async { Self.append(line) }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
