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
}
