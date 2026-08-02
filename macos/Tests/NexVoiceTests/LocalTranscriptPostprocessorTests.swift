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

    // MARK: - Filler word / self-correction cleanup (T8)

    func testBoundaryFillerBetweenPunctuationIsRemovedWithoutDoublingPunctuation() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "我想想，嗯，應該可以", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "我想想，應該可以"
        )
    }

    func testLeadingFillerFollowedByPunctuationIsRemoved() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "嗯，我要出門", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "我要出門"
        )
    }

    func testWholeTranscriptThatIsOnlyAFillerBecomesEmpty() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "嗯", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            ""
        )
    }

    func testFillerInTheMiddleOfAClauseIsNeverRemoved() {
        // "嗯嗯好" -- the fillers are followed by "好", not punctuation, another
        // filler, or end of string, so the whole clause is left untouched:
        // better to miss a filler than to risk chewing into real content.
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "嗯嗯好我知道了", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "嗯嗯好我知道了"
        )
    }

    func testRepeatedConnectorWordsAreFoldedNotDeleted() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "然後然後我們去吃飯", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "然後我們去吃飯"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "對對對就是這樣", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "對就是這樣"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "就是就是這個意思", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "就是這個意思"
        )
    }

    func testDangerousFillerCandidatesAreNeverTouched() {
        // 那個/這個/就是 are never in the standalone-deletion list at all --
        // deleting "那個" out of "那個按鈕" would corrupt the sentence.
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "那個按鈕改大一點", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "那個按鈕改大一點"
        )
    }

    func testSelfCorrectionMarkerDeletesShortPrecedingClause() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "先訂週三，不對，應該訂週四", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "應該訂週四"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "先訂週三，欸不對，應該訂週四", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "應該訂週四"
        )
    }

    func testSelfCorrectionMarkerWithoutPrecedingBoundaryDoesNotFire() {
        // R1 fix: "我是說"/"應該說"/bare "不對，" only trigger deletion when
        // immediately preceded by a clause boundary (or the start of the
        // transcript) -- see testSelfCorrectionFalsePositivesArePreservedVerbatim
        // below for the full regression set. Before the fix this used to
        // incorrectly delete "我要訂週三" and keep only "週四".
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "我要訂週三我是說週四", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "我要訂週三我是說週四"
        )
    }

    func testSelfCorrectionFalsePositivesArePreservedVerbatim() {
        // Regression set for the R1 bug: "我是說"/"應該說" had no boundary
        // condition at all, and bare "不對，" didn't require a real boundary
        // to its left either, so all of these used to be misread as
        // self-corrections and had real content deleted.
        let negatives = [
            "這件事我是說真的",
            "老闆問我是說要不要加班",
            "整體來看應該說還算成功",
            "這個數字不對，要重新算一次",
            "他說的不對，我們用另一個方案",
            "剛剛那句我是說",
            "這個不對，",
        ]
        for input in negatives {
            XCTAssertEqual(
                LocalTranscriptPostprocessor.preview(
                    input, vocabulary: [],
                    fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
                ),
                input,
                "expected '\(input)' to be preserved verbatim"
            )
        }
    }

    func testSelfCorrectionTruePositivesStillFireWithRealBoundary() {
        // These must still correctly self-correct: the marker is either
        // preceded by a real clause boundary ("，") or is "欸不對，", which is
        // exempt from the boundary check (see
        // boundaryExemptSelfCorrectionMarkers).
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "先訂週三，不對，訂週四", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "訂週四"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "那個欸不對，我要說的是B方案", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "我要說的是B方案"
        )
    }

    func testSelfCorrectionMarkerNeverFiresWhenPrecedingClauseIsTooLong() {
        // The clause before "應該說" here is well over 20 characters, so the
        // marker must be left untouched rather than risk deleting real content.
        let input = "這是一個很長很長很長很長很長很長很長很長很長的句子，應該說這句話重點是後面"
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                input, vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            input
        )
    }

    func testAsymmetricNotConfusedWithSelfCorrectionMarker() {
        // "不對稱" must not trigger the "不對，" marker -- there is no comma
        // directly after "不對" here, it is followed by "稱".
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "這是不對稱的設計", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "這是不對稱的設計"
        )
    }

    // MARK: - Additional postprocessor fixture coverage
    //
    // These two cases reuse the same fixture strings as
    // testSpokenPunctuationAndTraditionalChinese / the filler+self-correction
    // tests above, calling LocalTranscriptPostprocessor directly. They are
    // NOT a regression test for VoiceRuntimeController's raw-fallback branch
    // wiring (whether that branch actually invokes the postprocessor) --
    // proven by reverting VoiceRuntimeController.swift to its pre-fix state
    // while keeping these tests: they still pass, because they never touch
    // VoiceRuntimeController at all. VoiceRuntimeController's own branching
    // isn't directly unit-testable (it's wired into an async hotkey state
    // machine); these are honestly just more postprocessor fixture tests.

    func testPostprocessorAppliesSpokenPunctuationAndTraditionalChineseToRawFallbackFixture() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.process(
                "今天开会逗号明天再做句号",
                vocabulary: []
            ),
            "今天開會，明天再做。"
        )
    }

    func testPostprocessorAppliesFillerAndSelfCorrectionCleanupToRawFallbackFixture() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "先訂週三，不對，應該訂週四", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: true
            ),
            "應該訂週四"
        )
    }

    func testFillerAndSelfCorrectionCleanupCanBeDisabledIndependently() {
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "嗯，我要出門", vocabulary: [],
                fillerWordCleanupEnabled: false, selfCorrectionCleanupEnabled: true
            ),
            "嗯，我要出門"
        )
        XCTAssertEqual(
            LocalTranscriptPostprocessor.preview(
                "先訂週三，不對，應該訂週四", vocabulary: [],
                fillerWordCleanupEnabled: true, selfCorrectionCleanupEnabled: false
            ),
            "先訂週三，不對，應該訂週四"
        )
    }
}
