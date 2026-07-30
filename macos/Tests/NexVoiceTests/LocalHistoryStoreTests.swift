import XCTest
@testable import NexVoice

final class LocalHistoryStoreTests: XCTestCase {
    private func historyFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/nexvoice", isDirectory: true)
            .appendingPathComponent("local-history.json")
    }

    private func withTemporaryHistoryFile(json: String, _ body: () -> Void) {
        let url = historyFileURL()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = try? Data(contentsOf: url)
        defer {
            if let backup {
                try? backup.write(to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? Data(json.utf8).write(to: url)
        body()
    }

    func testLoadsLegacyHammerspoonSchema() {
        // Legacy desktop format used cleaned/raw/ts/engine, not the native
        // text/route/createdAt schema. This is the exact shape found in
        // ~/.cache/nexvoice/local-history.json (2026-07-12 incident).
        let legacyJSON = """
        [
          {
            "duration_ms": 246,
            "engine": "groq",
            "style": "tidy",
            "source": "desktop",
            "ts": "2026-07-12T05:28:41Z",
            "model": "",
            "id": "local-1783834121-3138",
            "cleaned": "直接開起來給我看，在 M5 店。",
            "raw": "直接開起來給我看,在M5店"
          }
        ]
        """
        withTemporaryHistoryFile(json: legacyJSON) {
            let entries = LocalHistoryStore.load()
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.text, "直接開起來給我看，在 M5 店。")
            XCTAssertEqual(entries.first?.route, "groq")
            XCTAssertEqual(entries.first?.createdAt, "2026-07-12T05:28:41Z")
        }
    }

    func testLoadsNativeSchema() {
        let nativeJSON = """
        [{"id": "abc", "text": "hello", "route": "localMLX", "createdAt": "2026-07-12T00:00:00Z"}]
        """
        withTemporaryHistoryFile(json: nativeJSON) {
            let entries = LocalHistoryStore.load()
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.text, "hello")
        }
    }

    func testSkipsEntriesWithNoUsableText() {
        let json = """
        [{"id": "x", "ts": "2026-07-12T00:00:00Z"}]
        """
        withTemporaryHistoryFile(json: json) {
            XCTAssertEqual(LocalHistoryStore.load().count, 0)
        }
    }
}
