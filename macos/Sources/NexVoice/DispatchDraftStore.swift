import Foundation

struct DispatchDraft: Codable, Equatable {
    let id: String
    let ts: String
    let source: String
    let status: String
    let text: String
    let note: String
}

enum DispatchDraftStore {
    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/nexvoice", isDirectory: true)
    }

    private static var jsonlURL: URL {
        directory.appendingPathComponent("dispatch-pending.jsonl")
    }

    enum DraftError: LocalizedError {
        case empty
        var errorDescription: String? { "沒有可派工的文字" }
    }

    /// Writes pending_approval draft only — never auto-runs Hermes/shell.
    @discardableResult
    static func create(text: String) throws -> DispatchDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DraftError.empty }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let id = "nv-dispatch-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...9999))"
        let entry = DispatchDraft(
            id: id,
            ts: ISO8601DateFormatter().string(from: Date()),
            source: "nexvoice-native",
            status: "pending_approval",
            text: trimmed,
            note: "Draft only — must not auto-run. Hermes/Kent approval required."
        )
        let line = try JSONEncoder().encode(entry) + Data("\n".utf8)
        if FileManager.default.fileExists(atPath: jsonlURL.path),
           let handle = try? FileHandle(forWritingTo: jsonlURL)
        {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: jsonlURL, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: jsonlURL.path
        )

        let md = directory.appendingPathComponent("dispatch-\(id).md")
        let body = """
        # NexVoice 派工草稿

        - id: `\(id)`
        - status: **pending_approval**
        - created: \(entry.ts)

        ## 內容

        \(trimmed)
        """
        try body.write(to: md, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: md.path
        )
        return entry
    }
}
