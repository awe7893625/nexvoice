import XCTest
@testable import NexVoice

final class TranscriptLanguageTests: XCTestCase {
    func testSimplifiedChineseIsNormalizedToTraditionalChinese() {
        XCTAssertEqual(
            TranscriptLanguage.traditionalChinese("这是语音速度测试"),
            "這是語音速度測試"
        )
    }

    func testLatinTextAndPunctuationArePreserved() {
        XCTAssertEqual(
            TranscriptLanguage.traditionalChinese("NexVoice API 2.0!"),
            "NexVoice API 2.0!"
        )
    }
}
