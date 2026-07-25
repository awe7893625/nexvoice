import XCTest
@testable import NexVoice

/// The gate decides what the HUD treats as silence, and the HUD's whole motion
/// budget hangs off that. The exponential tracker it replaced passed a review
/// only because nothing exercised it; these are the cases that broke it.
final class HUDNoiseGateTests: XCTestCase {
    private let interval = 0.04

    private func feed(_ gate: inout HUDNoiseGate, _ level: Double, seconds: Double) -> Double {
        var last = 0.0
        for _ in 0..<Int(seconds / interval) { last = gate.voiced(raw: level) }
        return last
    }

    func testSteadyRoomToneSettlesToSilence() {
        // A room humming at a constant 0.38 must read as silence, or every
        // waveform keeps drifting with nobody talking -- the exact complaint
        // this whole change answers.
        var gate = HUDNoiseGate()
        XCTAssertEqual(feed(&gate, 0.38, seconds: 3), 0, accuracy: 0.001)
        XCTAssertEqual(feed(&gate, 0.05, seconds: 3), 0, accuracy: 0.001)
    }

    func testSettlesWithinOneWindowNotHalfAMinute() {
        // The replaced tracker needed ~35s to rise onto a noisy room, so the
        // first half-minute of every recording was effectively ungated.
        var gate = HUDNoiseGate(windowSeconds: 2.5, sampleInterval: 0.04)
        _ = feed(&gate, 0.4, seconds: 2.6)
        XCTAssertEqual(gate.voiced(raw: 0.4), 0, accuracy: 0.001)
    }

    func testOpeningMidSentenceIsNotGated() {
        // Seeded with silence on purpose: if the window filled with the
        // opening shout, the speaker would be gated out for 2.5s.
        var gate = HUDNoiseGate()
        XCTAssertGreaterThan(gate.voiced(raw: 0.8), 0.7)
        XCTAssertGreaterThan(feed(&gate, 0.8, seconds: 1.0), 0.7)
    }

    func testSyllabicSpeechOverRoomToneStaysVoiced() {
        // Real speech dips between syllables; the floor should latch onto the
        // dips and still report the peaks loudly.
        var gate = HUDNoiseGate()
        var peak = 0.0
        for cycle in 0..<80 {
            let level = cycle.isMultiple(of: 2) ? 0.12 : 0.72
            let out = gate.voiced(raw: level)
            if cycle > 60, level > 0.5 { peak = max(peak, out) }
        }
        XCTAssertGreaterThan(peak, 0.45)
    }

    func testSustainedLoudInputIsNeverGatedAway() {
        // A long vowel or held note used to walk the old floor upward until it
        // silenced the speaker. The floor is capped so it cannot.
        var gate = HUDNoiseGate()
        XCTAssertGreaterThan(feed(&gate, 1.0, seconds: 60), 0.8)
        XCTAssertGreaterThan(feed(&gate, 0.75, seconds: 60), 0.25)
    }

    func testNaNAndOutOfRangeMeterReadingsCannotPropagate() {
        // A NaN would reach every shape's geometry; clamp comparisons pass it
        // through silently, so it is tested for explicitly.
        var gate = HUDNoiseGate()
        for raw in [Double.nan, .infinity, -.infinity, -5, 9] {
            let out = gate.voiced(raw: raw)
            XCTAssertFalse(out.isNaN, "raw=\(raw)")
            XCTAssertTrue(out >= 0 && out <= 1, "raw=\(raw) -> \(out)")
        }
    }

    func testFloorNeverExceedsItsCap() {
        var gate = HUDNoiseGate()
        _ = feed(&gate, 1.0, seconds: 120)
        XCTAssertLessThanOrEqual(gate.noiseFloor, 0.6)
    }
}
