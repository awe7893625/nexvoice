import Foundation
import XCTest
@testable import NexVoice

final class VoiceAPIContractTests: XCTestCase {
    func testLocalRequestCarriesStableSessionQualityAndCanonicalVocabulary() {
        let session = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let vocabulary = [
            VocabEntry(
                id: 1,
                phrase: "NexVoice",
                soundsLike: "next voice,nex voice",
                enabled: 1,
                ts: nil
            ),
            VocabEntry(
                id: 2,
                phrase: "Disabled",
                soundsLike: "disabled",
                enabled: 0,
                ts: nil
            )
        ]
        let object = VoiceAPI.localRequestObject(
            audio: Data([0x01, 0x02]),
            partial: true,
            sessionID: session,
            sequence: 7,
            vocabulary: vocabulary
        )

        XCTAssertEqual(object["session"] as? String, session.uuidString.lowercased())
        XCTAssertEqual(object["sequence"] as? Int, 7)
        XCTAssertEqual(object["quality"] as? String, "partial")
        XCTAssertEqual(object["vocab_terms"] as? [String], ["NexVoice"])
        XCTAssertEqual(object["audio_base64"] as? String, "AQI=")
    }

    func testLocalRequestClampsNegativeSequence() {
        let object = VoiceAPI.localRequestObject(
            audio: Data(),
            partial: false,
            sessionID: UUID(),
            sequence: -1,
            vocabulary: []
        )
        XCTAssertEqual(object["sequence"] as? Int, 0)
        XCTAssertEqual(object["quality"] as? String, "final")
    }

    func testFinalTranscribeTimeoutScalesWithAudioLength() {
        XCTAssertEqual(VoiceAPI.finalTranscribeTimeout(audioBytes: 0), 20, accuracy: 0.01)
        XCTAssertEqual(VoiceAPI.finalTranscribeTimeout(audioBytes: 32_000 * 60), 92, accuracy: 0.01)
        XCTAssertEqual(VoiceAPI.finalTranscribeTimeout(audioBytes: 32_000 * 600), 240, accuracy: 0.01)
    }

    // MARK: - Local-gateway cleanup fallback (third tier after Groq/Gemini)

    func testLocalGatewayRequestObjectCarriesTextAndTidyStyle() {
        let object = VoiceAPI.localGatewayRequestObject(text: "幫我看一下這個", appContext: nil)
        XCTAssertEqual(object["text"] as? String, "幫我看一下這個")
        XCTAssertEqual(object["style"] as? String, "tidy")
        XCTAssertNil(object["app_context"])
    }

    func testLocalGatewayRequestObjectIncludesNonEmptyAppContext() {
        let object = VoiceAPI.localGatewayRequestObject(text: "test", appContext: "Slack")
        XCTAssertEqual(object["app_context"] as? String, "Slack")
    }

    func testLocalGatewayRequestObjectOmitsEmptyAppContext() {
        // Mirrors Self.systemPrompt(_:appContext:)'s emptiness guard used by
        // the Groq/Gemini lanes -- an empty string must not be sent as if it
        // were a real app_context value.
        let object = VoiceAPI.localGatewayRequestObject(text: "test", appContext: "")
        XCTAssertNil(object["app_context"])
    }

    // MARK: - Local-gateway length gate
    //
    // Mirrors server/cleanup_v2.py's STRUCT_MIN_CPS = 80: above this many
    // content characters the server silently switches a "tidy" request into
    // struct_mode (numbered-bullet output), which the cloud-cleaned
    // postprocessing path would corrupt. The client must skip the
    // local-gateway tier entirely once content reaches that threshold.

    func testIsEligibleForLocalGatewayFallbackAcceptsShortContent() {
        // 79 CJK content characters -- one under the 80 threshold.
        let text = String(repeating: "字", count: 79)
        XCTAssertTrue(VoiceAPI.isEligibleForLocalGatewayFallback(text))
    }

    func testIsEligibleForLocalGatewayFallbackRejectsAtThreshold() {
        // Exactly 80 content characters must already be excluded -- the
        // server's own gate is ">= STRUCT_MIN_CPS", not "> STRUCT_MIN_CPS".
        let text = String(repeating: "字", count: 80)
        XCTAssertFalse(VoiceAPI.isEligibleForLocalGatewayFallback(text))
    }

    func testIsEligibleForLocalGatewayFallbackRejectsLongContent() {
        let text = String(repeating: "字", count: 200)
        XCTAssertFalse(VoiceAPI.isEligibleForLocalGatewayFallback(text))
    }

    func testIsEligibleForLocalGatewayFallbackIgnoresNonContentCharactersWhenCounting() {
        // Punctuation/whitespace/uppercase ASCII are not "content" per
        // CleanupFidelityGuard.contentChars (mirrors Python's _content_cps),
        // so padding a short transcript with them must not push it over the
        // threshold.
        let text = String(repeating: "字", count: 79) + String(repeating: "， ！？ABC", count: 20)
        XCTAssertTrue(VoiceAPI.isEligibleForLocalGatewayFallback(text))
    }

    // MARK: - Local-gateway response parsing

    func testParseLocalGatewayResponseExtractsAndTrimsText() throws {
        let data = try JSONSerialization.data(withJSONObject: ["text": "  已整理好的文字  "])
        XCTAssertEqual(try VoiceAPI.parseLocalGatewayResponse(data), "已整理好的文字")
    }

    func testParseLocalGatewayResponseThrowsWhenTextKeyMissing() {
        let data = try! JSONSerialization.data(withJSONObject: ["status": "ok"])
        XCTAssertThrowsError(try VoiceAPI.parseLocalGatewayResponse(data)) { error in
            guard case VoiceAPIError.invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func testParseLocalGatewayResponseThrowsWhenTextIsEmptyAfterTrim() {
        let data = try! JSONSerialization.data(withJSONObject: ["text": "   \n  "])
        XCTAssertThrowsError(try VoiceAPI.parseLocalGatewayResponse(data)) { error in
            guard case VoiceAPIError.invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    func testParseLocalGatewayResponseThrowsWhenTextExceedsMaxTranscriptBytes() {
        // maxTranscriptBytes is 65_536 in VoiceAPI.swift; one byte over must
        // be rejected, mirroring every other cleanup lane's byte-cap check.
        let oversized = String(repeating: "a", count: 65_537)
        let data = try! JSONSerialization.data(withJSONObject: ["text": oversized])
        XCTAssertThrowsError(try VoiceAPI.parseLocalGatewayResponse(data)) { error in
            guard case VoiceAPIError.invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }
}
