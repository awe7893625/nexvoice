import Foundation

/// How strict fidelity checking should be for a given cleanup lane.
/// Mirrors server/cleanup_v2.py's `tidy` vs `structure` guard thresholds.
enum CleanupFidelityMode {
    case tidy
    case organize
}

/// Pure-Swift fidelity guard for LLM-cleaned transcripts, mirroring the
/// Python guards in server/cleanup_v2.py (`_cleanup_looks_bad` /
/// `_structure_looks_bad`) so the macOS client rejects a bad cleanup
/// result even when it bypasses the server (direct Groq/Gemini calls).
enum CleanupFidelityGuard {
    /// Extract content characters: ASCII lowercase a-z, digits 0-9, and CJK
    /// 0x4E00-0x9FFF. Mirrors Python's `_content_cps` exactly, including its
    /// quirk of only counting lowercase ASCII letters as "content".
    static func contentChars(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return (0x61...0x7A).contains(value)
                || (0x30...0x39).contains(value)
                || (0x4E00...0x9FFF).contains(value)
        }
    }

    /// Longest common subsequence length between two scalar sequences.
    private static func lcsLength(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for scalarA in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 0..<b.count {
                if scalarA == b[j] {
                    cur[j + 1] = prev[j] + 1
                } else {
                    cur[j + 1] = Swift.max(prev[j + 1], cur[j])
                }
            }
            prev = cur
        }
        return prev[b.count]
    }

    private static let asciiWordRegex = try! NSRegularExpression(
        pattern: "[A-Za-z0-9][A-Za-z0-9._-]+"
    )

    /// Real ASCII word-like tokens (2+ chars), mirroring cleanup_v2.py's
    /// `_ascii_words` so mixed-language ASCII/technical terms aren't lost
    /// silently during organize-mode restructuring.
    private static func asciiWords(_ text: String) -> Set<String> {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return Set(asciiWordRegex.matches(in: text, range: range).map { ns.substring(with: $0.range) })
    }

    /// Whether `candidate` is an acceptable cleanup/organize result for
    /// `original`. A failing result must be discarded by the caller (fall
    /// through to another engine, or fall back to the original text).
    static func passes(original: String, candidate: String, mode: CleanupFidelityMode) -> Bool {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return false }

        let originalLength = original.count
        let candidateLength = trimmedCandidate.count
        let ratio = originalLength > 0 ? Double(candidateLength) / Double(originalLength) : 0

        switch mode {
        case .tidy:
            guard ratio >= 0.4 && ratio <= 1.4 else { return false }
        case .organize:
            guard ratio >= 0.25 && ratio <= 1.3 else { return false }
            let originalWords = asciiWords(original)
            if originalWords.count >= 3 {
                let candidateWords = asciiWords(trimmedCandidate)
                let retained = originalWords.intersection(candidateWords).count
                if Double(retained) / Double(originalWords.count) < 0.6 { return false }
            }
        }

        let originalContent = contentChars(original)
        let candidateContent = contentChars(trimmedCandidate)
        guard !originalContent.isEmpty else {
            // Nothing recognizable to score fidelity against; the ratio (and
            // ASCII-retention, for organize) gates above already covered it.
            return true
        }
        guard !candidateContent.isEmpty else { return false }

        let lcs = lcsLength(originalContent, candidateContent)
        let precision = Double(lcs) / Double(candidateContent.count)
        let recall = Double(lcs) / Double(originalContent.count)
        return precision >= 0.70 && recall >= 0.50
    }
}
