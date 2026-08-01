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
