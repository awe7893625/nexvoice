import Foundation

/// Persistent breadcrumb trail for the enable/Option pipeline so failures
/// that only show as "nothing happened" in the UI are diagnosable after
/// the fact, without needing to catch them live.
enum DiagnosticLog {
    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NexVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nexvoice.log")
    }()

    /// One log line can arrive from any thread (hotkey monitors run on the
    /// main actor, but background pipeline stages log too); serialize all
    /// file I/O here instead of blocking the caller's thread on every call.
    private static let queue = DispatchQueue(label: "ai.nexvoice.diagnostic-log", qos: .utility)

    /// Reused across calls -- constructing a fresh ISO8601DateFormatter per
    /// log line is measurable overhead when logging gets frequent (see
    /// `logVerbose` below, which exists precisely because logging got too
    /// frequent).
    nonisolated(unsafe) private static let dateFormatter = ISO8601DateFormatter()

    private static let maxFileSizeBytes: UInt64 = 5 * 1024 * 1024

    /// Verbose, per-event diagnostics (e.g. every raw flagsChanged event
    /// across three overlapping hotkey monitors) are opt-in: useful when
    /// actively debugging the hotkey pipeline itself, but writing a line to
    /// disk on every keystroke is not something normal operation should pay
    /// for. Off by default; set NEXVOICE_VERBOSE_HOTKEY_LOG=1 to opt in.
    private static let verboseEnabled = ProcessInfo.processInfo.environment["NEXVOICE_VERBOSE_HOTKEY_LOG"] == "1"

    static func log(_ message: String) {
        let timestamp = Date()
        queue.async {
            let stamp = dateFormatter.string(from: timestamp)
            let line = "[\(stamp)] \(message)\n"
            write(line)
        }
    }

    /// Same as `log`, but gated behind `verboseEnabled` and takes an
    /// autoclosure so callers on a hot path don't pay for string
    /// interpolation when the gate is closed.
    static func logVerbose(_ message: @autoclosure () -> String) {
        guard verboseEnabled else { return }
        log(message())
    }

    private static func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Only ever called from `write(_:)`, which itself only ever runs on
    /// `queue` -- keeps rotation from racing with an in-flight write.
    private static func rotateIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            size > maxFileSizeBytes
        else { return }
        let rotatedURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
    }
}
