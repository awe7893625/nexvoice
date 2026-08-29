import XCTest
@testable import NexVoice

final class TriggerKeyKeyCodeTests: XCTestCase {
    func testPhysicalModifierKeyCodesMapToSideSpecificTriggers() {
        let cases: [(UInt16, TriggerKey)] = [
            (58, .leftOption),
            (61, .rightOption),
            (55, .leftCommand),
            (54, .rightCommand),
            (59, .leftControl),
            (62, .rightControl),
            (63, .function),
        ]

        for (keyCode, expected) in cases {
            XCTAssertEqual(TriggerKey(keyCode: keyCode), expected)
        }
    }

    func testNonModifierKeyCodeDoesNotMapToTriggerKey() {
        XCTAssertNil(TriggerKey(keyCode: 49))
    }
}
