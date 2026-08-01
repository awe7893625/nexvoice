import XCTest
@testable import NexVoice

final class RoutingPolicyTests: XCTestCase {
    func testCalmHealthyM5UsesLocalMLX() {
        let route = RoutingPolicy().choose(
            RuntimeSnapshot(
                localHealthy: true,
                overloaded: false,
                localEnabled: true,
                groqConfigured: true,
                privacyMode: false
            )
        )
        XCTAssertEqual(route, .localMLX)
    }

    func testOverloadedM5UsesGroq() {
        let route = RoutingPolicy().choose(
            RuntimeSnapshot(
                localHealthy: true,
                overloaded: true,
                localEnabled: true,
                groqConfigured: true,
                privacyMode: false
            )
        )
        XCTAssertEqual(route, .groqWhisper)
    }

    func testZeroCostModeStillUsesBusyLocalServiceInsteadOfCloud() {
        let route = RoutingPolicy().choose(
            RuntimeSnapshot(
                localHealthy: true,
                overloaded: true,
                localEnabled: true,
                groqConfigured: false,
                privacyMode: false
            )
        )
        XCTAssertEqual(route, .localMLX)
    }

    func testConfiguredKeysDoNotAuthorizeCloudInZeroCostMode() {
        let preferences = RuntimePreferences(
            privacyMode: false,
            cleanupEnabled: false,
            smartFormatEnabled: false,
            localEnabled: true,
            localHealthy: true,
            overloaded: false,
            groqConfigured: true,
            cloudSTTAllowed: false,
            cloudTextAllowed: false,
            cloudTextConfigured: true
        )

        XCTAssertFalse(preferences.allowsCloudSTT)
        XCTAssertFalse(preferences.allowsCloudText)
        XCTAssertFalse(preferences.snapshot.groqConfigured)
    }

    func testPrivacyModeOverridesExplicitCloudToggles() {
        let preferences = RuntimePreferences(
            privacyMode: true,
            cleanupEnabled: true,
            smartFormatEnabled: false,
            localEnabled: true,
            localHealthy: false,
            overloaded: false,
            groqConfigured: true,
            cloudSTTAllowed: true,
            cloudTextAllowed: true,
            cloudTextConfigured: true
        )

        XCTAssertFalse(preferences.allowsCloudSTT)
        XCTAssertFalse(preferences.allowsCloudText)
        XCTAssertEqual(preferences.snapshot.groqConfigured, false)
    }

    func testCloudTextToggleWithoutCredentialsDoesNotAuthorizeRequests() {
        let preferences = RuntimePreferences(
            privacyMode: false,
            cleanupEnabled: true,
            smartFormatEnabled: false,
            localEnabled: true,
            localHealthy: true,
            overloaded: false,
            groqConfigured: false,
            cloudSTTAllowed: false,
            cloudTextAllowed: true,
            cloudTextConfigured: false
        )

        XCTAssertFalse(preferences.allowsCloudText)
    }

    func testPrivacyNeverFallsBackToCloud() {
        let route = RoutingPolicy().choose(
            RuntimeSnapshot(
                localHealthy: false,
                overloaded: false,
                localEnabled: true,
                groqConfigured: true,
                privacyMode: true
            )
        )
        XCTAssertEqual(route, .unavailable)
    }

    func testPasteGateAllowsAtMostOncePerSession() {
        let session = UUID()
        var gate = SessionPasteGate()
        gate.begin(session: session)
        XCTAssertTrue(gate.claimPaste(session: session))
        XCTAssertFalse(gate.claimPaste(session: session))
        XCTAssertFalse(gate.claimPaste(session: UUID()))
    }

    func testCancelledSessionCannotPaste() {
        let session = UUID()
        var gate = SessionPasteGate()
        gate.begin(session: session)
        gate.cancel(session: session)
        XCTAssertFalse(gate.claimPaste(session: session))
    }

    func testPasteGateRejectsOneThousandDuplicateClaims() {
        let session = UUID()
        var gate = SessionPasteGate()
        gate.begin(session: session)

        let accepted = (0..<1_000).filter { _ in gate.claimPaste(session: session) }

        XCTAssertEqual(accepted.count, 1)
    }

    func testRecordingMaxDurationIsWithinHardeningBand() {
        // Security residual: 2–5 minute cap against unbounded disk use.
        XCTAssertGreaterThanOrEqual(RecordingLimits.maxDurationSeconds, 120)
        XCTAssertLessThanOrEqual(RecordingLimits.maxDurationSeconds, 300)
        XCTAssertEqual(RecordingLimits.maxDurationSeconds, 180)
        XCTAssertEqual(RecordingLimits.minDurationSeconds, 0.35)
    }

    func testTranscriptGuardsRejectEmptyAndKnownHallucinations() {
        XCTAssertNil(TranscriptGuards.sanitize("   "))
        XCTAssertNil(TranscriptGuards.sanitize("Thanks for watching"))
        XCTAssertNil(TranscriptGuards.sanitize("謝謝觀看 謝謝觀看 謝謝觀看"))
        XCTAssertEqual(TranscriptGuards.sanitize("  明天開會改到三點  "), "明天開會改到三點")
    }

    func testTranscriptGuardsRejectCollapsedLoop() {
        let loop = String(repeating: "MR ", count: 40)
        XCTAssertTrue(TranscriptGuards.looksCollapsed(loop))
        XCTAssertNil(TranscriptGuards.sanitize(loop))
    }

    func testTranscriptGuardsAllowDictatedURLsAndCaptionMentions() {
        XCTAssertEqual(
            TranscriptGuards.sanitize("幫我看 github.com/anthropics 這個 repo"),
            "幫我看 github.com/anthropics 這個 repo"
        )
        XCTAssertEqual(
            TranscriptGuards.sanitize("幫我把字幕加上去"),
            "幫我把字幕加上去"
        )
        XCTAssertNil(TranscriptGuards.sanitize("字幕由 Amara.org 社群提供"))
        XCTAssertNil(TranscriptGuards.sanitize("請訂閱我的頻道"))
    }

    func testPrivacySnapshotBlocksCloudWhenLocalDown() {
        let route = RoutingPolicy().choose(
            RuntimeSnapshot(
                localHealthy: false,
                overloaded: true,
                localEnabled: true,
                groqConfigured: true,
                privacyMode: true
            )
        )
        XCTAssertEqual(route, .unavailable)
    }

    func testInstructionClassifierDistinguishesAskAndEdit() {
        XCTAssertEqual(SelectionService.classifyInstruction("總結這段"), .ask)
        XCTAssertEqual(SelectionService.classifyInstruction("解釋一下"), .ask)
        XCTAssertEqual(SelectionService.classifyInstruction("縮短一點"), .edit)
        XCTAssertEqual(SelectionService.classifyInstruction("改成更正式"), .edit)
    }

    func testSecretStoreUsesLocalFilesWithoutKeychainRoundTrip() {
        SecretStore.bootstrapLocalSecrets()
        // Must not crash; presence depends on machine secrets.
        _ = SecretStore.isSecureSecret(named: ".groq_key")
        _ = SecretStore.isSecureSecret(named: ".gemini_key")
        // Second call must hit memory cache only.
        _ = SecretStore.secret(named: ".groq_key")
        _ = SecretStore.secret(named: ".groq_key")
    }
}
