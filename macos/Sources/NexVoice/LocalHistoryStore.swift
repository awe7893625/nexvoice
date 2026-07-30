import Foundation

struct HistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let route: String
    let createdAt: String
}

/// Loads native + legacy Hammerspoon history from the same local file.
enum LocalHistoryStore {
    private static let maxEntries = 200

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/nexvoice", isDirectory: true)
            .appendingPathComponent("local-history.json")
    }

    static func append(text: String, route: STTRoute) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var entries = load()
        let entry = HistoryEntry(
            id: UUID().uuidString,
            text: text,
            route: route.rawValue,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        // Write unified native schema going forward (still readable by load).
        write(entries)
    }

    @discardableResult
    static func update(id: String, text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let old = entries[index]
        entries[index] = HistoryEntry(id: old.id, text: value, route: old.route, createdAt: old.createdAt)
        return write(entries)
    }

    @discardableResult
    static func delete(id: String) -> Bool {
        var entries = load()
        let oldCount = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != oldCount else { return false }
        return write(entries)
    }

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return raw.compactMap { mapLegacy($0) }
    }

    @discardableResult
    private static func write(_ entries: [HistoryEntry]) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(entries.map { NativeRecord(from: $0) }) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    /// Hammerspoon desktop format used `cleaned`/`raw`/`ts`/`engine`;
    /// native format uses `text`/`createdAt`/`route`.
    private static func mapLegacy(_ dict: [String: Any]) -> HistoryEntry? {
        let id = string(dict["id"]) ?? UUID().uuidString
        let text = firstNonEmpty(
            string(dict["text"]),
            string(dict["cleaned"]),
            string(dict["raw"])
        )
        guard let text, !text.isEmpty else { return nil }
        let route = firstNonEmpty(
            string(dict["route"]),
            string(dict["engine"]),
            string(dict["source"])
        ) ?? "legacy"
        let createdAt = firstNonEmpty(
            string(dict["createdAt"]),
            string(dict["ts"])
        ) ?? ISO8601DateFormatter().string(from: Date())
        return HistoryEntry(
            id: id,
            text: TranscriptLanguage.traditionalChinese(text),
            route: route,
            createdAt: createdAt
        )
    }

    private static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private struct NativeRecord: Codable {
        let id: String
        let text: String
        let route: String
        let createdAt: String
        init(from entry: HistoryEntry) {
            id = entry.id
            text = entry.text
            route = entry.route
            createdAt = entry.createdAt
        }
    }
}
