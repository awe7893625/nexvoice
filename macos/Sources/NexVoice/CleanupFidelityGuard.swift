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

    /// Longest common subsequence length between two scalar sequences, using
    /// the classic bit-parallel LCS algorithm (Allison & Dix, 1986): each DP
    /// row is packed into 64-bit words instead of one array cell per
    /// position, so the inner loop does O(m/64) word operations per row
    /// instead of O(m) scalar comparisons -- a ~64x reduction in iteration
    /// count. This matters because the straightforward two-array DP (still
    /// correct, still available in git history) measured ~1.6s at 4,000
    /// characters in a debug build -- almost entirely inner-loop overhead,
    /// not the per-row allocation -- which is too slow for a guard that runs
    /// on every cleanup result.
    ///
    /// Invariant: for DP row i (after consuming a[0..<i]), bit j (0-indexed)
    /// of the row's bit-vector is 1 iff dp[i][j+1] > dp[i][j] (both 1-indexed
    /// dp positions), i.e. the row's "step function" of where the running
    /// LCS length increases as b's prefix grows by one more character. This
    /// is a standard property of the LCS DP table (every step is 0 or +1),
    /// so popcount(row) after the last row equals dp[n][m] == LCS length.
    static func lcsLength(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        let m = b.count
        let wordCount = (m + 63) / 64
        let zero = [UInt64](repeating: 0, count: wordCount)

        // matchVectors[v] has bit j set iff b[j].value == v -- built once,
        // reused for every character of `a` that shares that value.
        var matchVectors: [UInt32: [UInt64]] = [:]
        for (j, scalar) in b.enumerated() {
            var vec = matchVectors[scalar.value] ?? zero
            vec[j / 64] |= (UInt64(1) << UInt64(j % 64))
            matchVectors[scalar.value] = vec
        }

        var row = zero
        for scalarA in a {
            let match = matchVectors[scalarA.value] ?? zero
            let x = orWords(row, match)
            let shifted = shiftLeftOneInjectingLowBit(row)
            let diff = subtractWithBorrow(x, shifted)
            row = andNotWords(x, diff)
        }

        return popcountMasked(row, bitCount: m)
    }

    private static func orWords(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: a.count)
        for i in 0..<a.count { result[i] = a[i] | b[i] }
        return result
    }

    private static func andNotWords(_ a: [UInt64], _ notThis: [UInt64]) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: a.count)
        for i in 0..<a.count { result[i] = a[i] & ~notThis[i] }
        return result
    }

    /// Shifts a multi-word big-endian-of-words (word 0 = least significant)
    /// bit vector left by one bit, injecting 1 into the new bit 0 -- the
    /// sentinel that represents the DP's fixed dp[i][0] = 0 boundary in the
    /// bit-parallel recurrence.
    private static func shiftLeftOneInjectingLowBit(_ v: [UInt64]) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: v.count)
        var carryIn: UInt64 = 1
        for i in 0..<v.count {
            result[i] = (v[i] << 1) | carryIn
            carryIn = v[i] >> 63
        }
        return result
    }

    /// Multi-word unsigned subtraction with borrow propagation (word 0 =
    /// least significant), matching the wraparound semantics a fixed-width
    /// bitset subtraction would have -- the bit-parallel recurrence relies on
    /// this wraparound, it is not a bug.
    private static func subtractWithBorrow(_ x: [UInt64], _ y: [UInt64]) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: x.count)
        var borrow: UInt64 = 0
        for i in 0..<x.count {
            let (partial, overflow1) = x[i].subtractingReportingOverflow(y[i])
            let (final, overflow2) = partial.subtractingReportingOverflow(borrow)
            result[i] = final
            borrow = (overflow1 || overflow2) ? 1 : 0
        }
        return result
    }

    /// Population count over only the first `bitCount` bits (word 0 = least
    /// significant); bits at or beyond `bitCount` are padding and excluded.
    private static func popcountMasked(_ v: [UInt64], bitCount: Int) -> Int {
        var total = 0
        let fullWords = bitCount / 64
        let remainder = bitCount % 64
        for i in 0..<fullWords {
            total += v[i].nonzeroBitCount
        }
        if remainder > 0, fullWords < v.count {
            let mask: UInt64 = (UInt64(1) << UInt64(remainder)) - 1
            total += (v[fullWords] & mask).nonzeroBitCount
        }
        return total
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

        // LCS is O(n*m); for very long transcripts this is a real latency
        // hit even with the buffer-reuse fix above. Beyond this size the
        // ratio (+ ASCII-retention, for organize) gates above already give a
        // reasonable fidelity signal, so skip the expensive precision/recall
        // check entirely rather than block the caller.
        guard originalContent.count <= 4000, candidateContent.count <= 4000 else {
            return true
        }

        let lcs = lcsLength(originalContent, candidateContent)
        let precision = Double(lcs) / Double(candidateContent.count)
        let recall = Double(lcs) / Double(originalContent.count)
        return precision >= 0.70 && recall >= 0.50
    }
}
