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

    func testOptionAcceptsEitherPhysicalOptionKeyOnly() {
        XCTAssertTrue(TriggerKey.option.accepts(keyCode: 58))
        XCTAssertTrue(TriggerKey.option.accepts(keyCode: 61))
        XCTAssertFalse(TriggerKey.option.accepts(keyCode: 49))
    }

    func testSideSpecificTriggersAcceptOnlyTheirOwnKeyCode() {
        let cases: [(TriggerKey, UInt16, UInt16)] = [
            (.leftOption, 58, 61),
            (.rightOption, 61, 58),
            (.leftCommand, 55, 54),
            (.rightCommand, 54, 55),
            (.leftControl, 59, 62),
            (.rightControl, 62, 59),
            (.function, 63, 58),
        ]

        for (trigger, ownCode, otherCode) in cases {
            XCTAssertTrue(trigger.accepts(keyCode: ownCode), "\(trigger) should accept \(ownCode)")
            XCTAssertFalse(trigger.accepts(keyCode: otherCode), "\(trigger) should reject \(otherCode)")
            XCTAssertFalse(trigger.accepts(keyCode: 49), "\(trigger) should reject 49")
        }
    }

    func testHotkeyProfileTransformsComposeWithoutStaleValues() {
        let schemaVersion = 7
        let base = HotkeyProfile(
            trigger: .leftOption,
            behavior: .pushToTalk,
            keyCode: 49,
            schemaVersion: schemaVersion
        )

        let triggerThenKeyCode = base
            .with(trigger: .rightOption)
            .with(keyCode: 36)
        XCTAssertEqual(triggerThenKeyCode.schemaVersion, schemaVersion)
        XCTAssertEqual(triggerThenKeyCode.trigger, .rightOption)
        XCTAssertEqual(triggerThenKeyCode.behavior, .pushToTalk)
        XCTAssertEqual(triggerThenKeyCode.keyCode, 36)

        let keyCodeThenTrigger = base
            .with(keyCode: 48)
            .with(trigger: .leftCommand)
        XCTAssertEqual(keyCodeThenTrigger.schemaVersion, schemaVersion)
        XCTAssertEqual(keyCodeThenTrigger.trigger, .leftCommand)
        XCTAssertEqual(keyCodeThenTrigger.behavior, .pushToTalk)
        XCTAssertNil(keyCodeThenTrigger.keyCode)

        let triggerTwice = base
            .with(trigger: .leftControl)
            .with(trigger: .function)
        XCTAssertEqual(triggerTwice.schemaVersion, schemaVersion)
        XCTAssertEqual(triggerTwice.trigger, .function)
        XCTAssertEqual(triggerTwice.behavior, .pushToTalk)
        XCTAssertNil(triggerTwice.keyCode)
    }
}
