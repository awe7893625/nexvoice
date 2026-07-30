import XCTest
@testable import NexVoice

final class HotkeyGestureEngineTests: XCTestCase {
    func testToggleStartsOnFirstPressAndFinishesOnSecondPress() {
        var engine = HotkeyGestureEngine(
            profile: HotkeyProfile(trigger: .option, behavior: .toggle)
        )

        XCTAssertEqual(engine.handle(.pressed, isRecording: false, canStart: true), .none)
        XCTAssertEqual(engine.handle(.pressed, isRecording: false, canStart: true), .none)
        XCTAssertEqual(engine.handle(.released, isRecording: false, canStart: true), .startRecording)
        XCTAssertEqual(engine.handle(.pressed, isRecording: true, canStart: false), .none)
        XCTAssertEqual(engine.handle(.released, isRecording: true, canStart: false), .finishRecording)
    }

    func testPushToTalkStartsOnPressAndFinishesOnRelease() {
        var engine = HotkeyGestureEngine(
            profile: HotkeyProfile(trigger: .rightOption, behavior: .pushToTalk)
        )

        XCTAssertEqual(
            engine.handle(.pressed, isRecording: false, canStart: true),
            .startRecording
        )
        XCTAssertEqual(engine.handle(.pressed, isRecording: true, canStart: false), .none)
        XCTAssertEqual(
            engine.handle(.released, isRecording: true, canStart: false),
            .finishRecording
        )
        XCTAssertEqual(engine.handle(.released, isRecording: false, canStart: true), .none)
    }

    func testPushToTalkReleaseDoesNotFinishUnrelatedSession() {
        var engine = HotkeyGestureEngine(
            profile: HotkeyProfile(trigger: .option, behavior: .pushToTalk)
        )
        XCTAssertEqual(engine.handle(.released, isRecording: true, canStart: false), .none)
    }

    func testProcessingStateCannotStartAnotherSession() {
        var engine = HotkeyGestureEngine()
        XCTAssertEqual(engine.handle(.pressed, isRecording: false, canStart: false), .none)
        XCTAssertEqual(engine.handle(.released, isRecording: false, canStart: false), .none)
    }

    func testProfileChangeResetsPhysicalEdge() {
        var engine = HotkeyGestureEngine()
        XCTAssertEqual(engine.handle(.pressed, isRecording: false, canStart: true), .none)
        engine.setProfile(HotkeyProfile(trigger: .leftControl, behavior: .pushToTalk))
        XCTAssertFalse(engine.triggerIsDown)
    }

    func testToggleEventStormProducesExactlyOneStartAndFinishPerSession() {
        var starts = 0
        var finishes = 0

        for _ in 0..<1_000 {
            var engine = HotkeyGestureEngine(
                profile: HotkeyProfile(trigger: .option, behavior: .toggle)
            )
            let firstPressEvents = (0..<8).map { _ in
                engine.handle(.pressed, isRecording: false, canStart: true)
            }
            let startEvents = firstPressEvents + (0..<8).map { _ in
                engine.handle(.released, isRecording: false, canStart: true)
            }
            let secondPressEvents = (0..<8).map { _ in
                engine.handle(.pressed, isRecording: true, canStart: false)
            }
            let finishEvents = secondPressEvents + (0..<8).map { _ in
                engine.handle(.released, isRecording: true, canStart: false)
            }
            starts += startEvents.filter { $0 == .startRecording }.count
            finishes += finishEvents.filter { $0 == .finishRecording }.count
        }

        XCTAssertEqual(starts, 1_000)
        XCTAssertEqual(finishes, 1_000)
    }

    func testToggleChordCancelsArmedTapWithoutStarting() {
        var engine = HotkeyGestureEngine()
        XCTAssertEqual(engine.handle(.pressed, isRecording: false, canStart: true), .none)
        XCTAssertEqual(engine.cancelForChord(isRecording: false), .none)
        XCTAssertEqual(engine.handle(.released, isRecording: false, canStart: true), .none)
    }

    func testPushToTalkChordCancelsRecording() {
        var engine = HotkeyGestureEngine(
            profile: HotkeyProfile(trigger: .option, behavior: .pushToTalk)
        )
        XCTAssertEqual(engine.handle(.pressed, isRecording: false, canStart: true), .startRecording)
        XCTAssertEqual(engine.cancelForChord(isRecording: true), .cancelRecording)
        XCTAssertEqual(engine.handle(.released, isRecording: false, canStart: true), .none)
    }

    func testPushToTalkEventStormProducesExactlyOneStartAndFinishPerSession() {
        var starts = 0
        var finishes = 0

        for _ in 0..<1_000 {
            var engine = HotkeyGestureEngine(
                profile: HotkeyProfile(trigger: .rightOption, behavior: .pushToTalk)
            )
            let pressEvents = (0..<8).map { _ in
                engine.handle(.pressed, isRecording: false, canStart: true)
            }
            let releaseEvents = (0..<8).map { _ in
                engine.handle(.released, isRecording: true, canStart: false)
            }
            starts += pressEvents.filter { $0 == .startRecording }.count
            finishes += releaseEvents.filter { $0 == .finishRecording }.count
        }

        XCTAssertEqual(starts, 1_000)
        XCTAssertEqual(finishes, 1_000)
    }
}
