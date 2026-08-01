import XCTest
@testable import NexVoice

final class TranscriptGuardsTests: XCTestCase {
    func testStrongHallucinationPhraseIsRejectedEvenInsideALongerLine() {
        // "请不吝点赞" is a strong-signal phrase (sponsor/outro boilerplate
        // Whisper hallucinates on silence); previously the guard only used
        // an 80%-coverage rule over the whole segment, which let a long
        // line containing it slip through.
        XCTAssertNil(
            TranscriptGuards.sanitize("请不吝点赞 订阅 转发 打赏支持明镜与点点栏目")
        )
    }

    func testStrongHallucinationPhraseIsRejectedInTraditionalChineseForm() {
        // The real pipeline (VoiceRuntimeController) runs simplified-to-
        // traditional normalization *before* this guard sees the text, so a
        // strongBadPhrases entry that only lists the simplified form would
        // never actually match at runtime. Every strong phrase needs both
        // forms listed (as "谢谢观看"/"謝謝觀看" already did).
        XCTAssertNil(
            TranscriptGuards.sanitize("請不吝點讚 訂閱 轉發 打賞支持明鏡與點點欄目")
        )
    }

    func testDictatedGithubRepoMentionIsAllowed() {
        XCTAssertEqual(
            TranscriptGuards.sanitize("幫我看 github.com/anthropics 這個 repo"),
            "幫我看 github.com/anthropics 這個 repo"
        )
    }

    func testDictatedSubtitleLocationQuestionIsAllowed() {
        XCTAssertEqual(
            TranscriptGuards.sanitize("我要查一下字幕的位置"),
            "我要查一下字幕的位置"
        )
    }

    func testDictatedSubtitleAdditionRequestIsAllowed() {
        XCTAssertEqual(
            TranscriptGuards.sanitize("幫我把字幕加上去"),
            "幫我把字幕加上去"
        )
    }
}
