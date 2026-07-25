import XCTest
@testable import NexVoice

/// The HUD's animation used to run off the wall clock, so every style moved at
/// the same speed whether or not anyone was speaking. These lock in the rule
/// that replaced it: phase advances with voice energy.
final class HUDMotionTests: XCTestCase {
    func testMotionRateRisesWithVoiceLevel() {
        let silent = nexVoiceHUDMotionRate(level: 0)
        let quiet = nexVoiceHUDMotionRate(level: 0.25)
        let speaking = nexVoiceHUDMotionRate(level: 0.75)
        let loud = nexVoiceHUDMotionRate(level: 1)

        XCTAssertLessThan(silent, quiet)
        XCTAssertLessThan(quiet, speaking)
        XCTAssertLessThan(speaking, loud)
        // Speech has to be unmistakably faster than silence, or the coupling
        // is there on paper but invisible on screen.
        XCTAssertGreaterThan(speaking / silent, 8)
    }

    func testMotionRateNeverStallsOrRunsBackwards() {
        // A dead-still HUD reads as a crashed indicator, so silence keeps a
        // small drift -- but it must stay a drift.
        XCTAssertGreaterThan(nexVoiceHUDMotionRate(level: 0), 0)
        XCTAssertLessThan(nexVoiceHUDMotionRate(level: 0), 0.2)
        XCTAssertGreaterThan(nexVoiceHUDMotionRate(level: -5), 0)
        XCTAssertEqual(nexVoiceHUDMotionRate(level: 9), nexVoiceHUDMotionRate(level: 1))
    }

    func testPreviewPhaseIsTheIntegralOfTheSameMotionLaw() {
        // The settings tiles must demonstrate the live behaviour, not a
        // separate constant-speed animation. Differentiating the closed-form
        // preview phase has to reproduce the live rate at that level.
        let dt = 0.0005
        for time in stride(from: 0.0, through: 12.0, by: 0.37) {
            let before = nexVoiceHUDPreviewSignal(at: time - dt)
            let after = nexVoiceHUDPreviewSignal(at: time + dt)
            let measured = (after.phase - before.phase) / (2 * dt)
            let expected = nexVoiceHUDMotionRate(level: nexVoiceHUDPreviewSignal(at: time).level)
            XCTAssertEqual(measured, expected, accuracy: 0.001, "at t=\(time)")
        }
    }

    func testPreviewPhaseAdvancesMonotonically() {
        // Non-monotonic phase would make waveforms visibly stutter backwards.
        var previous = -Double.infinity
        for time in stride(from: 0.0, through: 30.0, by: 0.05) {
            let phase = nexVoiceHUDPreviewSignal(at: time).phase
            XCTAssertGreaterThan(phase, previous, "at t=\(time)")
            previous = phase
        }
    }

    func testPreviewLevelSweepsTheFullRange() {
        // A tile that only ever shows mid-level tells you nothing about how
        // the style looks when you actually raise your voice.
        let levels = stride(from: 0.0, through: 12.0, by: 0.05)
            .map { nexVoiceHUDPreviewSignal(at: $0).level }
        XCTAssertLessThan(levels.min() ?? 1, 0.02)
        XCTAssertGreaterThan(levels.max() ?? 0, 0.98)
        XCTAssertTrue(levels.allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 })
    }
}
