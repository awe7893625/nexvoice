import Foundation

/// Separates speech from room tone before the HUD sees a level.
///
/// The HUD's animation is driven by voice energy, so whatever the microphone
/// reports while nobody is talking sets the floor of "still". `meterLevel()`
/// already subtracts a *fixed* offset, but a real room lands anywhere from
/// 0.1 to 0.5 on that scale, and anything left over keeps every waveform
/// drifting — which looks exactly like ignoring the voice.
///
/// Estimated by **min-hold**: the quietest reading in a short trailing window.
/// Speech has gaps between syllables, so the minimum tracks the room without
/// being dragged up by sustained voice. The exponential tracker this replaced
/// had to choose between lagging ~50s on the way up (leaving the first half
/// minute of every recording ungated) and creeping up during long vowels
/// until it gated the speaker out entirely.
struct HUDNoiseGate {
    /// Never trust an estimate above this: past it, the gate could silence
    /// everything, and a dead HUD is worse than a slightly restless one.
    private static let maxFloor = 0.6
    /// Margin above the floor that still counts as silence.
    private static let deadband = 0.03

    private let capacity: Int
    private var recent: [Double]

    init(windowSeconds: Double = 2.5, sampleInterval: Double = 0.04) {
        capacity = max(1, Int((windowSeconds / max(0.001, sampleInterval)).rounded()))
        // Seeded with silence so a recording that opens mid-sentence is not
        // gated for a whole window. Failing toward "responsive" is right:
        // too much motion for 2.5s is a blemish, a frozen HUD reads as a crash.
        recent = Array(repeating: 0, count: capacity)
    }

    /// Current room-tone estimate, for diagnostics.
    var noiseFloor: Double { min(Self.maxFloor, recent.min() ?? 0) }

    /// Feed one raw meter reading, get back the voiced level in 0...1.
    mutating func voiced(raw: Double) -> Double {
        // A NaN from the meter would otherwise propagate into every shape;
        // clamp comparisons silently pass NaN through, so test for it.
        let clamped = raw.isNaN ? 0 : max(0, min(1, raw))
        recent.append(clamped)
        if recent.count > capacity { recent.removeFirst() }

        let floor = noiseFloor
        let span = max(0.25, 1 - floor)
        return max(0, min(1, (clamped - floor - Self.deadband) / span))
    }
}
