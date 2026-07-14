import Foundation

/// Drop empty, whisper-hallucinated, or collapsed-loop transcripts before paste.
enum TranscriptGuards {
    private static let badPhrases: [String] = [
        "thank you for watching",
        "thanks for watching",
        "subscribe",
        "字幕",
        "请不吝点赞",
        "谢谢观看",
        "謝謝觀看",
        "谢谢收看",
        "謝謝收看",
        "ご視聴",
        "チャンネル登録",
        "www.",
        "http://",
        "https://",
        ".com/",
        "mr mr",
        "【音乐】",
        "[music]",
        "(music)",
        "applause",
        "鼓掌"
    ]

    static func sanitize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !looksGarbage(trimmed) else { return nil }
        guard !looksCollapsed(trimmed) else { return nil }
        return trimmed
    }

    static func looksCollapsed(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.filter { $0.value > 32 })
        guard scalars.count >= 30 else { return false }
        let distinct = Set(scalars.map(\.value)).count
        return Double(distinct) / Double(scalars.count) < 0.25
    }

    static func looksGarbage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let low = trimmed.lowercased()
        if badPhrases.contains(where: { low.contains($0) }) { return true }

        var total = 0
        var letters = 0
        var symbols = 0
        for scalar in trimmed.unicodeScalars where scalar.value > 32 {
            total += 1
            let cp = scalar.value
            let isLetter =
                (cp >= 48 && cp <= 57)
                || (cp >= 65 && cp <= 90)
                || (cp >= 97 && cp <= 122)
                || (cp >= 0x4E00 && cp <= 0x9FFF)
                || (cp >= 0x3040 && cp <= 0x30FF)
                || (cp >= 0xAC00 && cp <= 0xD7AF)
            let isOkPunct =
                (cp >= 0x3000 && cp <= 0x303F)
                || cp == 0x2C || cp == 0x2E || cp == 0x21 || cp == 0x3F
                || cp == 0x3A || cp == 0x3B || cp == 0x27 || cp == 0x22
                || cp == 0x28 || cp == 0x29 || cp == 0x2D || cp == 0x2F
            if isLetter {
                letters += 1
            } else if !isOkPunct {
                symbols += 1
            }
        }
        if total == 0 { return true }
        if Double(symbols) / Double(total) >= 0.30 { return true }
        if total >= 6 && Double(letters) / Double(total) < 0.40 { return true }
        if total <= 6 && letters == 0 { return true }
        return looksCollapsed(trimmed)
    }
}
