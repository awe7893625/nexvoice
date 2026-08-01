import Foundation

/// Drop empty, whisper-hallucinated, or collapsed-loop transcripts before paste.
enum TranscriptGuards {
    /// Strong-signal hallucination phrases: these never legitimately appear
    /// in real dictation (sponsor/outro boilerplate Whisper hallucinates on
    /// silence), so a plain substring match anywhere in the transcript is
    /// enough to reject it outright -- unlike weakBadPhrases below, this is
    /// NOT limited to short segments, because these phrases are never a
    /// coincidental fragment of otherwise-normal long dictation.
    private static let strongBadPhrases: [String] = [
        "请不吝点赞",
        "谢谢观看",
        "謝謝觀看",
        "谢谢收看",
        "謝謝收看",
        "thank you for watching",
        "thanks for watching",
        "ご視聴",
        "チャンネル登録",
        "字幕由 Amara.org",
        "打赏",
        "明镜与点点"
    ]

    /// Weak-signal phrases: plausible enough as a coincidental fragment of
    /// real dictation (e.g. "字幕" is a normal word to dictate on its own)
    /// that they only reject a segment via the short-segment (<30
    /// normalized chars) coverage heuristic in looksLikeKnownHallucination,
    /// never as a bare substring match.
    private static let weakBadPhrases: [String] = [
        "請訂閱我的頻道",
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

    /// Normalize for hallucination matching: strip whitespace, punctuation,
    /// and symbol characters, then lowercase. Keeps letters/digits/CJK content.
    private static func normalizedForHallucinationMatch(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
    }

    /// A transcript containing a strong-signal phrase as a plain substring
    /// (after the same normalization used elsewhere in this file) is always
    /// rejected, regardless of the transcript's overall length.
    private static func containsStrongHallucination(_ text: String) -> Bool {
        let normalizedText = normalizedForHallucinationMatch(text)
        guard !normalizedText.isEmpty else { return false }
        for phrase in strongBadPhrases {
            let normalizedPhrase = normalizedForHallucinationMatch(phrase)
            guard !normalizedPhrase.isEmpty else { continue }
            if normalizedText.contains(normalizedPhrase) { return true }
        }
        return false
    }

    /// A whole segment "looks like" a known (weak-signal) hallucinated
    /// phrase when either:
    /// - the segment is a short truncated fragment of a longer known phrase
    ///   (segment is a substring of the phrase, covering >80% of it), or
    /// - the segment is mostly made up of one or more repetitions of a known
    ///   phrase (non-overlapping occurrences cover >80% of the segment).
    /// This only applies to short segments (<30 normalized characters) so it
    /// cannot misfire on long, otherwise-normal dictation that merely mentions
    /// a related word (e.g. a dictated URL, or the word "字幕").
    private static func looksLikeKnownHallucination(_ text: String) -> Bool {
        let normalizedText = normalizedForHallucinationMatch(text)
        guard !normalizedText.isEmpty, normalizedText.count < 30 else { return false }
        for phrase in weakBadPhrases {
            let normalizedPhrase = normalizedForHallucinationMatch(phrase)
            guard !normalizedPhrase.isEmpty else { continue }
            if normalizedText.count <= normalizedPhrase.count {
                guard normalizedPhrase.contains(normalizedText) else { continue }
                let coverage = Double(normalizedText.count) / Double(normalizedPhrase.count)
                if coverage > 0.8 { return true }
            } else {
                let occurrences = normalizedText.components(separatedBy: normalizedPhrase).count - 1
                guard occurrences > 0 else { continue }
                let covered = occurrences * normalizedPhrase.count
                let coverage = Double(covered) / Double(normalizedText.count)
                if coverage > 0.8 { return true }
            }
        }
        return false
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

        if containsStrongHallucination(trimmed) { return true }
        if looksLikeKnownHallucination(trimmed) { return true }

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
