import Foundation

/// Separator scalars treated as optional "noise" inside a sounds-like variant
/// (e.g. the "、" MLX sometimes inserts between ASCII letters, or a spoken
/// "dot"/"dash" transcribed literally). Shared by VocabularyPolicy (to reject
/// variants that are pure noise) and LocalTranscriptPostprocessor (to build
/// the flexible match pattern), so the two stay in lock-step.
fileprivate let variantSeparatorCharacterSet = CharacterSet.whitespacesAndNewlines.union(
    CharacterSet(charactersIn: ",，、._-")
)

enum VocabularyPolicy {
    static let maxEntries = 256
    static let maxVariantsPerEntry = 8
    static let maxFieldBytes = 128
    static let maxPromptTerms = 64
    static let maxPromptTermsBytes = 1_536

    static func normalizedPhrase(_ value: String) -> String? {
        normalizedField(value)
    }

    static func normalizedVariants(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .compactMap(normalizedField)
            .filter(hasNonSeparatorContent)
            .reduce(into: [String]()) { result, variant in
                guard result.count < maxVariantsPerEntry else { return }
                let key = variant.lowercased()
                guard !result.contains(where: { $0.lowercased() == key }) else { return }
                result.append(variant)
            }
    }

    /// Rejects variants made entirely of separator noise (".", "-", "_", ",", "、", whitespace).
    /// Such a variant would compile to a regex whose entire body is the optional
    /// separator class, i.e. something that can match a zero-length range anywhere
    /// in the text -- see LocalTranscriptPostprocessor P0-A.
    private static func hasNonSeparatorContent(_ variant: String) -> Bool {
        variant.unicodeScalars.contains { !variantSeparatorCharacterSet.contains($0) }
    }

    static func sanitizedEntries(_ entries: [VocabEntry]) -> [VocabEntry] {
        entries.prefix(maxEntries).compactMap { entry in
            guard let phrase = normalizedPhrase(entry.phrase) else { return nil }
            let soundsLike = normalizedVariants(entry.soundsLike).joined(separator: ",")
            return VocabEntry(
                id: entry.id,
                phrase: phrase,
                soundsLike: soundsLike,
                enabled: entry.enabled == 0 ? 0 : 1,
                ts: entry.ts
            )
        }
    }

    static func promptTerms(from entries: [VocabEntry]) -> [String] {
        var result: [String] = []
        var usedBytes = 0
        var seen = Set<String>()
        for entry in sanitizedEntries(entries) where entry.enabled != 0 {
            guard result.count < maxPromptTerms else { break }
            let key = entry.phrase.lowercased()
            guard seen.insert(key).inserted else { continue }
            let bytes = entry.phrase.utf8.count
            guard usedBytes + bytes <= maxPromptTermsBytes else { continue }
            result.append(entry.phrase)
            usedBytes += bytes
        }
        return result
    }

    private static func normalizedField(_ value: String) -> String? {
        let normalized = TranscriptLanguage.traditionalChinese(
            value.precomposedStringWithCanonicalMapping
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maxFieldBytes,
              !normalized.unicodeScalars.contains(where: isUnsafeScalar)
        else { return nil }
        return normalized
    }

    private static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value < 0x20
            || (0x7F...0x9F).contains(value)
            || (0x200B...0x200F).contains(value)
            || (0x2028...0x202E).contains(value)
            || (0x2060...0x206F).contains(value)
            || value == 0xFEFF
    }
}

/// Thread-safe cache of compiled regexes, keyed by pattern+options. Vocabulary-derived
/// patterns are re-derived from the same snapshot on every keystroke of live preview;
/// without this cache a 256-entry/8-variant vocabulary recompiles up to ~2,300 regexes
/// per call (measured ~469ms for 34,000 chars). Bounded by VocabularyPolicy limits.
private final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private var storage: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(for pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[key] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        storage[key] = compiled
        return compiled
    }
}

/// Fast, deterministic local-only transcript cleanup. This is deliberately
/// conservative: it corrects configured vocabulary, understands dictated
/// punctuation, inserts clause separators at strong connectors, and supplies
/// a terminal mark. It never calls a model, network service, or tool.
enum LocalTranscriptPostprocessor {
    private struct ReplacementCandidate {
        let range: NSRange
        let replacement: String
        let sequence: Int
    }

    static func process(
        _ text: String,
        vocabulary: [VocabEntry],
        fillerWordCleanupEnabled: Bool = ProductPreferencesStore.load().fillerWordCleanupEnabled,
        selfCorrectionCleanupEnabled: Bool = ProductPreferencesStore.load().selfCorrectionCleanupEnabled
    ) -> String {
        let (protectedText, mapping) = protectSpans(in: normalizeScript(text))
        var result = applyProseCleanup(
            protectedText,
            vocabulary: vocabulary,
            fillerWordCleanupEnabled: fillerWordCleanupEnabled,
            selfCorrectionCleanupEnabled: selfCorrectionCleanupEnabled
        )
        result = insertClauseSeparators(result)
        result = ensureTerminalPunctuation(result, mapping: mapping)
        return restoreSpans(result, mapping: mapping)
    }

    static func preview(
        _ text: String,
        vocabulary: [VocabEntry],
        fillerWordCleanupEnabled: Bool = ProductPreferencesStore.load().fillerWordCleanupEnabled,
        selfCorrectionCleanupEnabled: Bool = ProductPreferencesStore.load().selfCorrectionCleanupEnabled
    ) -> String {
        let (protectedText, mapping) = protectSpans(in: normalizeScript(text))
        let result = applyProseCleanup(
            protectedText,
            vocabulary: vocabulary,
            fillerWordCleanupEnabled: fillerWordCleanupEnabled,
            selfCorrectionCleanupEnabled: selfCorrectionCleanupEnabled
        )
        return restoreSpans(result, mapping: mapping)
    }

    private static func normalizeScript(_ text: String) -> String {
        TranscriptLanguage.traditionalChinese(text.precomposedStringWithCanonicalMapping)
    }

    private static func applyProseCleanup(
        _ text: String,
        vocabulary: [VocabEntry],
        fillerWordCleanupEnabled: Bool,
        selfCorrectionCleanupEnabled: Bool
    ) -> String {
        var result = applyVocabulary(text, vocabulary: vocabulary)
        result = replaceSpokenPunctuation(result)
        result = demoteClausalDunhao(result)
        if fillerWordCleanupEnabled {
            result = foldRepeatedConnectors(result)
            result = removeBoundaryClauseFillers(result)
        }
        if selfCorrectionCleanupEnabled {
            result = removeSelfCorrections(result)
        }
        result = normalizePunctuationClusters(result)
        return normalizeWhitespace(result)
    }

    /// Filler tokens deleted only when they form an entire clause by
    /// themselves: bounded on the left by punctuation or the start of the
    /// transcript, and on the right by punctuation, another filler token, or
    /// the end of the transcript. Never removed mid-clause, and never
    /// includes 那個/這個/就是 at all -- deleting "那個" out of "那個按鈕"
    /// would corrupt the sentence, so those three are simply too dangerous to
    /// ever put in this list (see foldRepeatedConnectors below for the one
    /// transformation that IS safe for 就是: collapsing an immediate stutter,
    /// which never deletes the word outright).
    ///
    /// The trailing boundary is consumed (not just matched via lookahead) so
    /// only the *leading* punctuation survives as the clause separator --
    /// otherwise a filler clause bounded by punctuation on both sides (e.g.
    /// "我想想，嗯，應該可以") would leave the two flanking marks stranded
    /// next to each other ("我想想，，應該可以").
    private static let boundaryClauseFillerPattern =
        "(?:^|(?<=[，。！？；：、,.!?;:…\\n]))(?:嗯|呃|欸|um|uh)+(?:[，。！？；：、,.!?;:…\\n]|$)"

    private static func removeBoundaryClauseFillers(_ text: String) -> String {
        guard let regex = RegexCache.shared.regex(
            for: boundaryClauseFillerPattern, options: [.caseInsensitive]
        ) else { return text }
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// Collapses an immediate stutter of a connector word into a single
    /// instance: "然後然後" -> "然後", "對對對" -> "對", "就是就是" -> "就是".
    /// This never deletes the word entirely (unlike removeBoundaryClauseFillers
    /// above), so it stays safe even for 就是, which must never be deleted
    /// outright.
    private static let repeatedConnectorPattern = "(然後|對|就是)\\1+"

    private static func foldRepeatedConnectors(_ text: String) -> String {
        guard let regex = RegexCache.shared.regex(for: repeatedConnectorPattern) else { return text }
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
    }

    /// Explicit self-correction markers. Order does not affect matching
    /// (each starts with a distinct character), but the longer variant is
    /// listed first for readability.
    private static let selfCorrectionMarkers = ["欸不對，", "不對，", "我是說", "應該說"]

    /// For each marker occurrence, if the clause immediately preceding it is
    /// <=20 characters long, deletes that clause and the marker itself,
    /// keeping only what comes after the marker -- e.g. "先訂週三，不對，應該
    /// 訂週四" -> "應該訂週四". A single directly-adjacent boundary
    /// punctuation mark between the clause and the marker (the "，" in that
    /// example) is deleted along with them so no dangling leading punctuation
    /// survives. If the preceding clause is longer than 20 characters, the
    /// marker is left untouched -- better to miss a correction than to risk
    /// deleting real content the user didn't intend to retract.
    private static func removeSelfCorrections(_ text: String) -> String {
        let markerPattern = selfCorrectionMarkers
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard let regex = RegexCache.shared.regex(for: markerPattern) else { return text }
        let boundary = Set("，。！？；：、,.!?;:…\n")

        var working = text
        var searchFrom = working.startIndex
        while searchFrom < working.endIndex {
            let searchRange = NSRange(searchFrom..<working.endIndex, in: working)
            guard let match = regex.firstMatch(in: working, range: searchRange),
                  let markerRange = Range(match.range, in: working)
            else { break }

            var clauseEnd = markerRange.lowerBound
            if clauseEnd > working.startIndex {
                let before = working.index(before: clauseEnd)
                if boundary.contains(working[before]) {
                    clauseEnd = before
                }
            }
            var clauseStart = clauseEnd
            while clauseStart > working.startIndex {
                let before = working.index(before: clauseStart)
                if boundary.contains(working[before]) { break }
                clauseStart = before
            }

            let clauseLength = working.distance(from: clauseStart, to: clauseEnd)
            if clauseLength <= 20 {
                working.removeSubrange(clauseStart..<markerRange.upperBound)
                searchFrom = clauseStart
            } else {
                searchFrom = markerRange.upperBound
            }
        }
        return working
    }

    /// 頓號 is only correct between short parallel items（「蘋果、香蕉」）。The
    /// MLX decoder also drops it between full clauses; when either side of a
    /// 、 is a long span (7+ units, ASCII runs counted as one unit), that 、
    /// is a mis-punctuated clause break and reads better as 逗號.
    private static func demoteClausalDunhao(_ text: String) -> String {
        guard text.contains("、") else { return text }
        let punctuation = Set("，。！？；：、,.!?;:…\n")
        let characters = Array(text)

        func units(in range: Range<Int>) -> Int {
            var count = 0
            var insideASCIIRun = false
            for index in range {
                let character = characters[index]
                if character.isWhitespace {
                    insideASCIIRun = false
                } else if character.unicodeScalars.allSatisfy(\.isASCII) {
                    if !insideASCIIRun { count += 1 }
                    insideASCIIRun = true
                } else {
                    insideASCIIRun = false
                    count += 1
                }
            }
            return count
        }

        var result = ""
        result.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            guard character == "、" else {
                result.append(character)
                continue
            }
            var left = index - 1
            while left >= 0, !punctuation.contains(characters[left]) { left -= 1 }
            var right = index + 1
            while right < characters.count, !punctuation.contains(characters[right]) { right += 1 }
            let leftUnits = units(in: (left + 1)..<index)
            let rightUnits = units(in: (index + 1)..<right)
            result.append(leftUnits >= 7 || rightUnits >= 7 ? "，" : "、")
        }
        return result
    }

    // MARK: - URL / email / code span protection (P0-B)

    /// Placeholder spans use Private Use Area scalars, which never appear in real
    /// ASR output and never match any vocabulary/punctuation/connector pattern, so
    /// they pass through the whole prose pipeline inert and get swapped back verbatim.
    private static func placeholderToken(_ index: Int) -> String {
        "\u{E000}\(index)\u{E001}"
    }

    private static let urlPattern = "(?:https?://|www\\.)\\S+"
    private static let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"

    private static let trailingTrimCharacterSet = CharacterSet(
        charactersIn: "，。！？；：,.!?;:、\"')]}」』》〉"
    )

    private static func protectSpans(in text: String) -> (String, [String: String]) {
        var mapping: [String: String] = [:]

        let codeProtectedLines = text.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, isLikelyCodeLine(trimmed) else { return line }
            let token = placeholderToken(mapping.count)
            mapping[token] = trimmed
            return token
        }
        var protectedText = codeProtectedLines.joined(separator: "\n")

        protectedText = replacingSpans(in: protectedText, pattern: urlPattern, mapping: &mapping)
        protectedText = replacingSpans(in: protectedText, pattern: emailPattern, mapping: &mapping)

        return (protectedText, mapping)
    }

    private static func replacingSpans(
        in text: String,
        pattern: String,
        mapping: inout [String: String]
    ) -> String {
        guard let regex = RegexCache.shared.regex(for: pattern) else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            let trimmed = trimTrailingPunctuation(from: match.range, in: source)
            guard trimmed.length > 0 else { continue }
            let original = source.substring(with: trimmed)
            let token = placeholderToken(mapping.count)
            mapping[token] = original
            output.replaceCharacters(in: trimmed, with: token)
        }
        return output as String
    }

    private static func trimTrailingPunctuation(from range: NSRange, in source: NSString) -> NSRange {
        var length = range.length
        while length > 0 {
            let lastScalarRange = NSRange(location: range.location + length - 1, length: 1)
            let lastChar = source.substring(with: lastScalarRange)
            guard let scalar = lastChar.unicodeScalars.first,
                  trailingTrimCharacterSet.contains(scalar)
            else { break }
            length -= 1
        }
        return NSRange(location: range.location, length: length)
    }

    private static func restoreSpans(_ text: String, mapping: [String: String]) -> String {
        guard !mapping.isEmpty else { return text }
        var result = text
        for (token, original) in mapping {
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }

    private static func cjkCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if (0x3400...0x9FFF).contains(scalar.value) { count += 1 }
        }
    }

    private static func isLikelyCodeLine(_ text: String) -> Bool {
        guard cjkCharacterCount(in: text) < 2 else { return false }
        return text.contains("=") || text.contains("{") || text.contains("}")
    }

    // MARK: - Vocabulary application

    static func applyVocabulary(_ text: String, vocabulary: [VocabEntry]) -> String {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var candidates: [ReplacementCandidate] = []

        for entry in VocabularyPolicy.sanitizedEntries(vocabulary) where entry.enabled != 0 {
            let phraseKey = entry.phrase.lowercased()
            if let pattern = canonicalASCIIRepairPattern(for: entry.phrase),
               let regex = RegexCache.shared.regex(for: pattern, options: [.caseInsensitive]) {
                for match in regex.matches(in: text, range: fullRange) where match.range.length > 0 {
                    let matched = source.substring(with: match.range)
                    guard matched.caseInsensitiveCompare(entry.phrase) != .orderedSame else {
                        continue
                    }
                    candidates.append(
                        ReplacementCandidate(
                            range: match.range,
                            replacement: entry.phrase,
                            sequence: candidates.count
                        )
                    )
                }
            }
            for variant in VocabularyPolicy.normalizedVariants(entry.soundsLike) {
                let variantKey = variant.lowercased()
                guard variantKey != phraseKey,
                      !phraseKey.contains(variantKey)
                else { continue }

                let pattern = flexibleVariantPattern(for: variant)
                guard let regex = RegexCache.shared.regex(for: pattern, options: [.caseInsensitive]) else {
                    continue
                }
                for match in regex.matches(in: text, range: fullRange) where match.range.length > 0 {
                    candidates.append(
                        ReplacementCandidate(
                            range: match.range,
                            replacement: entry.phrase,
                            sequence: candidates.count
                        )
                    )
                }
            }
        }

        candidates.sort {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            if $0.range.length != $1.range.length {
                return $0.range.length > $1.range.length
            }
            // Explicit tie-break for identical range/length candidates: don't rely
            // on sort-algorithm stability, use the original scan order.
            return $0.sequence < $1.sequence
        }

        var selected: [ReplacementCandidate] = []
        var nextAvailableLocation = 0
        for candidate in candidates where candidate.range.location >= nextAvailableLocation {
            selected.append(candidate)
            nextAvailableLocation = NSMaxRange(candidate.range)
        }

        let output = NSMutableString(string: text)
        for candidate in selected.reversed() {
            output.replaceCharacters(in: candidate.range, with: candidate.replacement)
        }
        return output as String
    }

    private static let flexibleSeparatorPattern = "[\\s\\x{00A0},，、._-]*"

    private static func flexibleVariantPattern(for variant: String) -> String {
        var body = ""
        var isInsideSeparator = false
        for scalar in variant.unicodeScalars {
            if variantSeparatorCharacterSet.contains(scalar) {
                if !isInsideSeparator { body += flexibleSeparatorPattern }
                isInsideSeparator = true
            } else {
                body += NSRegularExpression.escapedPattern(for: String(scalar))
                isInsideSeparator = false
            }
        }
        return asciiBoundaryPattern(for: variant, body: body)
    }

    private static func canonicalASCIIRepairPattern(for phrase: String) -> String? {
        let scalars = Array(phrase.unicodeScalars)
        guard scalars.count >= 3, scalars.allSatisfy(isASCIIWordScalar) else { return nil }
        let body = scalars
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: flexibleSeparatorPattern)
        return asciiBoundaryPattern(for: phrase, body: body)
    }

    /// Word-boundary assertions are derived from the first/last *non-separator*
    /// scalar, not the raw first/last scalar. Otherwise a variant like ".net" (or
    /// "cat-") drops its boundary check on the separator side and the flexible
    /// separator class -- which matches zero characters -- lets it match "net"
    /// inside "internet" or "cat" inside "category". See P0-C.
    private static func asciiBoundaryPattern(for variant: String, body: String) -> String {
        let coreScalars = variant.unicodeScalars.filter { !variantSeparatorCharacterSet.contains($0) }
        let prefix = coreScalars.first.map(isASCIIWordScalar) == true ? "(?<![A-Za-z0-9_])" : ""
        let suffix = coreScalars.last.map(isASCIIWordScalar) == true ? "(?![A-Za-z0-9_])" : ""
        return prefix + body + suffix
    }

    private static func isASCIIWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
            || value == 95
    }

    private static func replaceSpokenPunctuation(_ text: String) -> String {
        let replacements: [(String, String)] = [
            ("換下一段", "\n\n"), ("下一段", "\n\n"), ("new paragraph", "\n\n"),
            ("驚嘆號", "！"), ("感嘆號", "！"), ("exclamation mark", "！"),
            ("question mark", "？"), ("full stop", "。"),
            ("換下一行", "\n"), ("下一行", "\n"), ("new line", "\n"),
            ("逗號", "，"), ("逗點", "，"), ("comma", "，"),
            ("句號", "。"), ("句點", "。"), ("period", "。"),
            ("問號", "？"), ("冒號", "："), ("分號", "；")
        ]
        return replacements.reduce(text) { partial, item in
            let hasASCIIWordEdge = item.0.unicodeScalars.contains(where: isASCIIWordScalar)
            guard hasASCIIWordEdge else {
                return partial.replacingOccurrences(of: item.0, with: item.1)
            }
            let escaped = NSRegularExpression.escapedPattern(for: item.0)
            let pattern = "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])"
            guard let regex = RegexCache.shared.regex(for: pattern, options: [.caseInsensitive]) else {
                return partial
            }
            return regex.stringByReplacingMatches(
                in: partial,
                range: NSRange(location: 0, length: (partial as NSString).length),
                withTemplate: item.1
            )
        }
    }

    private static func normalizePunctuationClusters(_ text: String) -> String {
        // Tolerate whitespace between terminal marks (e.g. "嗎 ? 問號 。" after word
        // substitution becomes "嗎 ? ？ 。" -- a purely-contiguous {2,} class never
        // matches that, so the redundant marks survive uncollapsed). See P0-C.
        let pattern = "[。.!！?？](?:[\\s\\x{00A0}]*[。.!！?？])+"
        guard let terminalRegex = RegexCache.shared.regex(for: pattern) else {
            return text
        }
        let source = text as NSString
        let matches = terminalRegex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            let cluster = source.substring(with: match.range)
            let replacement: String
            if cluster.contains("?") || cluster.contains("？") {
                replacement = "？"
            } else if cluster.contains("!") || cluster.contains("！") {
                replacement = "！"
            } else {
                replacement = "。"
            }
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return (output as String)
            .replacingOccurrences(of: "[，,]{2,}", with: "，", options: .regularExpression)
            .replacingOccurrences(of: "[；;]{2,}", with: "；", options: .regularExpression)
            .replacingOccurrences(of: "[：:]{2,}", with: "：", options: .regularExpression)
            // A lone halfwidth terminal mark directly after a CJK character is a
            // model artifact ("...修好了嗎?"); widen it. URL/email/code spans are
            // already behind placeholder tokens, and marks after Latin text are
            // left alone, so "Is this ok?" keeps its halfwidth form.
            .replacingOccurrences(of: "([\\x{3400}-\\x{9FFF}])\\?", with: "$1？", options: .regularExpression)
            .replacingOccurrences(of: "([\\x{3400}-\\x{9FFF}])!", with: "$1！", options: .regularExpression)
            // Halfwidth comma/period squeezed between two CJK characters is the
            // same decoder artifact; "1,000" and "v1.2" keep their ASCII marks
            // because both neighbors must be CJK.
            .replacingOccurrences(
                of: "([\\x{3400}-\\x{9FFF}]),(?=[\\x{3400}-\\x{9FFF}])",
                with: "$1，",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "([\\x{3400}-\\x{9FFF}])\\.(?=[\\x{3400}-\\x{9FFF}])",
                with: "$1。",
                options: .regularExpression
            )
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "[ \\t\\u{00A0}]+",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "[ ]+([，。！？；：、])",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "([，。！？；：、])[ ]+",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "([（「『【《〈])[ ]+",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "[ ]+([）」』】》〉])",
            with: "$1",
            options: .regularExpression
        )
        let lines = result.components(separatedBy: .newlines)
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func insertClauseSeparators(_ text: String) -> String {
        let connectors = [
            "儘管如此", "換句話說", "除此之外", "與此同時",
            "然後", "但是", "不過", "所以", "另外", "接著",
            "而且", "可是", "因此", "因為", "如果", "同時"
        ]
        var output = ""
        var index = text.startIndex
        var clauseLength = 0
        let separators = CharacterSet(charactersIn: "，。！？；：,.!?;:\n")

        while index < text.endIndex {
            let tail = text[index...]
            if let connector = connectors.first(where: { tail.hasPrefix($0) }) {
                if clauseLength >= 8,
                   output.last.map({ !isSeparator($0, in: separators) }) == true {
                    output.append("，")
                    clauseLength = 0
                }
                output.append(connector)
                clauseLength += connector.count
                index = text.index(index, offsetBy: connector.count)
                continue
            }

            let character = text[index]
            output.append(character)
            if isSeparator(character, in: separators) {
                clauseLength = 0
            } else if !character.isWhitespace {
                clauseLength += 1
            }
            index = text.index(after: index)
        }
        return output
    }

    private static func isSeparator(_ character: Character, in set: CharacterSet) -> Bool {
        character.unicodeScalars.allSatisfy { set.contains($0) }
    }

    private static func ensureTerminalPunctuation(_ text: String, mapping: [String: String]) -> String {
        text.components(separatedBy: .newlines).map { line in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "" }
            // A line that is exactly one protected URL/email/code span must not
            // have punctuation appended based on its (opaque) placeholder token.
            guard mapping[trimmed] == nil else { return trimmed }
            if let last = trimmed.last, "。！？.!?…".contains(last) {
                return trimmed
            }
            guard shouldAppendTerminal(to: trimmed) else { return trimmed }
            while let last = trimmed.last, "，、；：,;:".contains(last) {
                trimmed.removeLast()
            }
            return trimmed + (looksLikeQuestion(trimmed) ? "？" : "。")
        }.joined(separator: "\n")
    }

    private static func looksLikeQuestion(_ text: String) -> Bool {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["嗎", "呢", "麼", "嘛"].contains(where: { compact.hasSuffix($0) }) {
            return true
        }
        let questionPrefixes = [
            "請問", "為什麼", "怎麼", "哪裡", "哪個", "誰", "什麼",
            "多少", "幾點", "何時", "是否", "是不是", "有沒有",
            "可不可以", "能不能", "在哪"
        ]
        if questionPrefixes.contains(where: { compact.hasPrefix($0) }) {
            return true
        }
        let questionSuffixes = [
            "為什麼", "怎麼辦", "在哪裡", "在哪", "哪裡", "哪個",
            "是什麼", "有多少", "幾點", "何時"
        ]
        if questionSuffixes.contains(where: { compact.hasSuffix($0) }) {
            return true
        }
        let commandPrefixes = [
            "檢查", "請檢查", "確認", "請確認", "記錄", "測試", "判斷", "列出"
        ]
        if commandPrefixes.contains(where: { compact.hasPrefix($0) }) {
            return false
        }
        if ["有沒有", "可不可以", "能不能", "是不是"].contains(where: { compact.contains($0) }) {
            return true
        }
        let lower = compact.lowercased()
        return [
            "who ", "what ", "when ", "where ", "why ", "how ",
            "is ", "are ", "do ", "does ", "did ", "can ", "could ",
            "would ", "will ", "should "
        ].contains(where: { lower.hasPrefix($0) })
    }

    private static func shouldAppendTerminal(to text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("://")
            || (lower.contains("@") && lower.contains("."))
            || lower.hasPrefix("/")
            || [".swift", ".py", ".json", ".md", ".yaml", ".yml", ".html", ".css", ".js"]
                .contains(where: { lower.hasSuffix($0) }) {
            return false
        }
        if cjkCharacterCount(in: text) >= 2 { return true }
        if isLikelyCodeLine(text) { return false }
        return text.split(whereSeparator: { $0.isWhitespace }).count >= 3
    }
}
