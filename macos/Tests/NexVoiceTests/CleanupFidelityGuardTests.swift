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

    // MARK: - Performance (bit-parallel LCS / long-transcript skip)

    func testLargeTranscriptFidelityCheckStaysFast() {
        // Regression test: the original per-row-allocating DP measured
        // ~1.6s at 4,000 chars in a debug build -- and a two-buffer-swap
        // variant barely helped (~1.59s), because the dominant cost is the
        // O(n*m) scalar comparisons/bounds-checks themselves, not the
        // allocation. lcsLength now uses a bit-parallel (64-bits-per-word)
        // DP, cutting the effective inner-loop iteration count by ~64x. At
        // exactly the 4,000-char boundary the LCS check still runs in full
        // (not skipped by the size guard below), so this proves the
        // algorithmic fix itself.
        let original = String(repeating: "這是一段很長的逐字稿內容測試效能", count: 250)
        XCTAssertEqual(original.count, 4000)
        let candidate = original

        let start = Date()
        let result = CleanupFidelityGuard.passes(original: original, candidate: candidate, mode: .tidy)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result)
        XCTAssertLessThan(elapsed, 0.5, "fidelity check at 4,000 chars took \(elapsed)s")
    }

    func testTranscriptBeyondSizeGuardSkipsLcsAndStillPasses() {
        // Beyond 4,000 content characters the LCS precision/recall check is
        // skipped entirely (ratio + ASCII-retention gates already covered
        // above); this exercises the guard's `> 4000` branch and confirms it
        // fails open (returns true) rather than blocking on it.
        let original = String(repeating: "這是一段很長的逐字稿內容測試效能", count: 400)
        XCTAssertGreaterThan(original.count, 4000)
        let candidate = original

        let start = Date()
        let result = CleanupFidelityGuard.passes(original: original, candidate: candidate, mode: .tidy)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result)
        XCTAssertLessThan(elapsed, 0.5, "fidelity check beyond 4,000 chars took \(elapsed)s")
    }

    // MARK: - lcsLength correctness (bit-parallel vs. naive reference)

    /// Textbook O(n*m) LCS length, kept ONLY in this test file as a trusted
    /// reference to fuzz-check the production bit-parallel implementation
    /// against. Deliberately not shared code with CleanupFidelityGuard.
    private func naiveLcsLength(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for scalarA in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 0..<b.count {
                cur[j + 1] = scalarA == b[j] ? prev[j] + 1 : Swift.max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return prev[b.count]
    }

    private func assertLcsMatchesReference(
        _ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let aScalars = Array(a.unicodeScalars)
        let bScalars = Array(b.unicodeScalars)
        let expected = naiveLcsLength(aScalars, bScalars)
        let actual = CleanupFidelityGuard.lcsLength(aScalars, bScalars)
        XCTAssertEqual(
            actual, expected,
            "lcsLength(\(a.debugDescription), \(b.debugDescription)) = \(actual), expected \(expected)",
            file: file, line: line
        )
    }

    func testLcsLengthMatchesReferenceOnEdgeCases() {
        assertLcsMatchesReference("", "")
        assertLcsMatchesReference("abc", "")
        assertLcsMatchesReference("", "abc")
        assertLcsMatchesReference("abc", "abc")
        assertLcsMatchesReference("abc", "xyz")
        assertLcsMatchesReference("ABCDGH", "AEDFHR")
        assertLcsMatchesReference("我在想我們是不是要改一下顏色", "嗯我在想說那個我們是不是要改一下顏色")
        assertLcsMatchesReference("aaaaaaaaaa", "aaaaaaaaaa")
        assertLcsMatchesReference(String(repeating: "a", count: 130), String(repeating: "a", count: 130))
        // Spans a 64-bit word boundary (63/64/65 characters) in both directions.
        assertLcsMatchesReference(String(repeating: "中", count: 63), String(repeating: "中", count: 65))
        assertLcsMatchesReference(String(repeating: "中文", count: 40), String(repeating: "文中", count: 33))
    }

    func testLcsLengthMatchesReferenceOnRandomFuzzInputs() {
        // Small alphabet, short-ish lengths (naive reference is O(n*m), keep
        // it cheap) but enough random cases and lengths (including ones that
        // straddle a 64-bit word boundary) to exercise the bit-parallel
        // implementation's word-boundary/borrow-propagation logic.
        var rng = SystemRandomNumberGenerator()
        let alphabet: [Character] = ["a", "b", "c", "中", "文", "1"]
        for _ in 0..<200 {
            let lenA = Int.random(in: 0...140, using: &rng)
            let lenB = Int.random(in: 0...140, using: &rng)
            let a = String((0..<lenA).map { _ in alphabet.randomElement(using: &rng)! })
            let b = String((0..<lenB).map { _ in alphabet.randomElement(using: &rng)! })
            assertLcsMatchesReference(a, b)
        }
    }
}
