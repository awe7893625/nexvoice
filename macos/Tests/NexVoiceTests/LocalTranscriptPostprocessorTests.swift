import XCTest
@testable import NexVoice

final class LocalTranscriptPostprocessorTests: XCTestCase {
    private func entry(
        _ phrase: String,
        sounds: String,
        enabled: Int = 1,
        id: Int = 1
    ) -> VocabEntry {
        VocabEntry(id: id, phrase: phrase, soundsLike: sounds, enabled: enabled, ts: nil)
    }

    func testSpokenPunctuationAndTraditionalChinese() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process(
                "今天开会逗号明天再做句号",
                vocabulary: []
            ),
            "今天開會，明天再做。"
        )
    }

    func testEnglishSpokenPunctuationDoesNotCorruptLargerWords() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "command periodic comma next",
                vocabulary: []
            ),
            "command periodic，next"
        )
    }

    func testQuestionGetsQuestionMark() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("請問 MLX 服務在哪裡", vocabulary: []),
            "請問 MLX 服務在哪裡？"
        )
    }

    func testStatementGetsFullStop() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("NexVoice API 2.0", vocabulary: []),
            "NexVoice API 2.0。"
        )
    }

    func testURLAndCodeLikeTextAreNotForcedIntoProse() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("https://example.com/api", vocabulary: []),
            "https://example.com/api"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("let value = 1", vocabulary: []),
            "let value = 1"
        )
    }

    func testEmbeddedQuestionCueDoesNotTurnStatementIntoQuestion() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("這裡會記錄設定是否開啟的狀態", vocabulary: []),
            "這裡會記錄設定是否開啟的狀態。"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("檢查有沒有遺漏資料", vocabulary: []),
            "檢查有沒有遺漏資料。"
        )
    }

    func testLongestVariantWinsWithoutCascade() {
        let vocabulary = [
            entry("NexVoice", sounds: "next voice,next voices,nex voice", id: 1),
            entry("SomethingElse", sounds: "NexVoice", id: 2)
        ]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "請開啟 next voices API",
                vocabulary: vocabulary
            ),
            "請開啟 NexVoice API"
        )
    }

    func testASCIIReplacementUsesWordBoundaries() {
        let vocabulary = [entry("dog", sounds: "cat")]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "concatenate cat category",
                vocabulary: vocabulary
            ),
            "concatenate dog category"
        )
    }

    func testDisabledVocabularyIsIgnored() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "next voice",
                vocabulary: [entry("NexVoice", sounds: "next voice", enabled: 0)]
            ),
            "next voice"
        )
    }

    func testFullWidthVariantDelimiterIsSupported() {
        let vocabulary = [entry("NexVoice", sounds: "next voice，nex voice")]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview("nex voice", vocabulary: vocabulary),
            "NexVoice"
        )
    }

    func testVocabularyRepairsSeparatorNoiseInsideASCIIIdentifiers() {
        let vocabulary = [entry("NexVoice", sounds: "next voice,nex voice")]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview("Nex、Voice", vocabulary: vocabulary),
            "NexVoice"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview("next、voice", vocabulary: vocabulary),
            "NexVoice"
        )
    }

    func testRealMLXStylePunctuationClusterIsNormalized() {
        let vocabulary = [
            entry("NexVoice", sounds: "next voice,nex voice", id: 1),
            entry("NexPilot", sounds: "next pilot,nex pilot", id: 2)
        ]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process(
                "今天開會逗號明天再做句號Nex、Voice和NexPilot都準備好了嗎?問號。",
                vocabulary: vocabulary
            ),
            "今天開會，明天再做。NexVoice和NexPilot都準備好了嗎？"
        )
    }

    func testCanonicalSubstringVariantDoesNotCorruptCanonicalText() {
        let vocabulary = [entry("workflow", sounds: "work,workflow")]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview("workflow", vocabulary: vocabulary),
            "workflow"
        )
    }

    func testConnectorsReceiveConservativeClauseSeparators() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process(
                "我們先完成本機測試但是如果失敗就停止貼上所以不要自動切雲端",
                vocabulary: []
            ),
            "我們先完成本機測試，但是如果失敗就停止貼上，所以不要自動切雲端。"
        )
    }

    func testUnsafeOrOversizedVocabularyIsExcludedFromPrompt() {
        let unsafe = entry("IGNORE\nSYSTEM", sounds: "ignore", id: 1)
        let huge = entry(String(repeating: "a", count: 129), sounds: "large", id: 2)
        let safe = entry("NexVoice", sounds: "next voice", id: 3)
        XCTAssertEqual(VocabularyPolicy.promptTerms(from: [unsafe, huge, safe]), ["NexVoice"])
    }

    // MARK: - P0-A: separator-only variants must never produce a zero-length match

    func testSeparatorOnlyVariantIsRejectedFromVocabulary() {
        XCTAssertEqual(VocabularyPolicy.normalizedVariants("-,.,_"), [])
        XCTAssertEqual(VocabularyPolicy.normalizedVariants("--,NexVoice,__"), ["NexVoice"])
    }

    func testPunctuationOnlyVariantDoesNotCorruptOrHangOnLongText() {
        let vocabulary = [entry("NexVoice", sounds: "-", id: 1)]
        let longText = String(repeating: "今天天氣很好。", count: 500)
        let result = LocalTranscriptPostprocessor.preview(longText, vocabulary: vocabulary)
        XCTAssertEqual(result, longText)
    }

    // MARK: - P0-B: URL / email / code spans must survive prose postprocessing untouched

    func testCommaWordInsideURLIsNotConvertedToPunctuation() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("https://example.com/comma", vocabulary: []),
            "https://example.com/comma"
        )
    }

    func testCodeAssignmentLineIsNotMangledByVocabularyOrPunctuation() {
        let vocabulary = [entry("comma", sounds: "comma")]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("let comma = 1", vocabulary: vocabulary),
            "let comma = 1"
        )
    }

    func testConnectorInsideURLPathIsNotTurnedIntoClauseSeparator() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process(
                "https://example.com/但是/x",
                vocabulary: []
            ),
            "https://example.com/但是/x"
        )
    }

    func testProseSurroundingProtectedURLSpanIsStillCleanedUp() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process(
                "看看 https://example.com/comma 這個連結逗號很重要",
                vocabulary: []
            ),
            "看看 https://example.com/comma 這個連結，很重要。"
        )
    }

    func testEmailAddressIsNotMangledByPunctuationWords() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("foo.comma@example.com", vocabulary: []),
            "foo.comma@example.com"
        )
    }

    // MARK: - P0-C: leading/trailing-separator variant boundaries

    func testLeadingSeparatorVariantDoesNotMatchInsideLargerWord() {
        let vocabulary = [entry("DotNetRuntime", sounds: ".net", id: 1)]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview("internet speed test", vocabulary: vocabulary),
            "internet speed test"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview("site.net is up", vocabulary: vocabulary),
            "site.DotNetRuntime is up"
        )
    }

    func testTrailingSeparatorVariantDoesNotMatchInsideLargerWord() {
        let vocabulary = [entry("cat food", sounds: "cat-", id: 1)]
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview("category theory", vocabulary: vocabulary),
            "category theory"
        )
    }

    // MARK: - P0-C: spaced terminal-punctuation clusters must still collapse

    func testSpacedTerminalPunctuationClusterCollapses() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("在嗎 ? 問號 。", vocabulary: []),
            "在嗎？"
        )
    }

    func testLoneHalfwidthTerminalMarkAfterCJKIsWidened() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("NexVoice已經修好了嗎?", vocabulary: []),
            "NexVoice已經修好了嗎？"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("太好了!", vocabulary: []),
            "太好了！"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview("Is this ok?", vocabulary: []),
            "Is this ok?"
        )
    }

    // MARK: - P0-C: deterministic tie-break for same-range same-length candidates

    func testSameRangeSameLengthCandidatesUseDeterministicFirstEntryWins() {
        let vocabulary = [
            entry("Alpha", sounds: "xyz", id: 1),
            entry("Beta", sounds: "xyz", id: 2)
        ]
        let first = LocalTranscriptPostprocessor.preview("say xyz now", vocabulary: vocabulary)
        let second = LocalTranscriptPostprocessor.preview("say xyz now", vocabulary: vocabulary)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "say Alpha now")
    }

    // MARK: - P0-C: worst-case 256 x 8 vocabulary performance

    func testWorstCaseVocabularyPerformsWithinBudget() {
        var vocabulary: [VocabEntry] = []
        for i in 0..<256 {
            let variants = (0..<8).map { "variant\(i)-\($0)" }.joined(separator: ",")
            vocabulary.append(entry("Canonical\(i)", sounds: variants, id: i))
        }
        let longText = String(repeating: "今天開會討論下一步計畫但是還沒有結論所以先休息。", count: 400)

        let start = Date()
        _ = LocalTranscriptPostprocessor.preview(longText, vocabulary: vocabulary)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "worst-case vocabulary preview took \(elapsed)s")
    }

    func testClausalDunhaoIsDemotedToComma() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("我看了整份報表、然後把部署流程重新跑了一遍", vocabulary: []),
            "我看了整份報表，然後把部署流程重新跑了一遍。"
        )
    }

    func testShortListDunhaoIsPreserved() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("我買了蘋果、香蕉、鳳梨", vocabulary: []),
            "我買了蘋果、香蕉、鳳梨。"
        )
    }

    func testAsciiProductListDunhaoIsPreserved() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process("NexVoice、NexPilot 都要更新", vocabulary: []),
            "NexVoice、NexPilot 都要更新。"
        )
    }
}
