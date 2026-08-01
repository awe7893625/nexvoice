import XCTest
@testable import NexVoice

final class CleanupFidelityGuardTests: XCTestCase {
    // MARK: - tidy mode

    func testTidyValidLightweightCleanupPasses() {
        let original = "嗯我在想說那個我們是不是要改一下顏色"
        let candidate = "我在想我們是不是要改一下顏色。"
        XCTAssertTrue(
            CleanupFidelityGuard.passes(original: original, candidate: candidate, mode: .tidy)
        )
    }

    func testTidyOutputCollapsedToAlmostNothingFails() {
        let original = "我們今天開會討論一下下週的發布計畫然後前端後端都要準備好測試案例"
        let candidate = "好的"
        XCTAssertFalse(
            CleanupFidelityGuard.passes(original: original, candidate: candidate, mode: .tidy)
        )
    }

    func testTidyBloatedOutputFails() {
        let original = "嗯這個功能真的很好用"
        let candidate = "這個功能真的很好用啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊"
        XCTAssertFalse(
            CleanupFidelityGuard.passes(original: original, candidate: candidate, mode: .tidy)
        )
    }

    // MARK: - organize mode

    func testOrganizeValidRestructurePasses() {
        let original =
            "我們討論了一下下週的計畫第一個是前端要確認設計稿第二個是後端要補齊API文件第三個是要準備好測試案例第四個是行銷要準備文案"
        let candidate =
            "1. 前端：要確認設計稿\n2. 後端：要補齊 API 文件\n3. 測試：要準備好測試案例\n4. 行銷：要準備文案"
        XCTAssertTrue(
            CleanupFidelityGuard.passes(original: original, candidate: candidate, mode: .organize)
        )
    }

    func testOrganizeAsciiWordLossFails() {
        let original =
            "please make sure to sync with github and slack about the release notes and also update jira"
        let candidate = "已同步"
        XCTAssertFalse(
            CleanupFidelityGuard.passes(original: original, candidate: candidate, mode: .organize)
        )
    }

    func testOrganizeOverCompressedRecallFails() {
        let original =
            "我們今天開會討論了很多事情包含前端後端測試行銷業務財務法務還有客服總共七個部門都要參與這次的計畫確保順利推行"
        let candidate = "開會了"
        XCTAssertFalse(
            CleanupFidelityGuard.passes(original: original, candidate: candidate, mode: .organize)
        )
    }
}
