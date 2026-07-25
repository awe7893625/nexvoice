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
}
