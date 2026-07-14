import AppKit
import SwiftUI

@MainActor
final class CompactRecorderHUD {
    private var panel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var meterTimer: Timer?
    private var smoothedLevel = 0.05
    private let model = RecorderHUDModel()
    private var liveCaptionsEnabled = true
    var meterProvider: (() -> Double)?

    func configure(style: HUDStyle, liveCaptionsEnabled: Bool, subtitleStyle: SubtitleStyle) {
        model.style = style
        model.subtitleStyle = subtitleStyle
        self.liveCaptionsEnabled = liveCaptionsEnabled
        if !liveCaptionsEnabled {
            model.partialText = ""
            subtitlePanel?.orderOut(nil)
        }
    }

    func show() {
        if panel == nil { panel = makePanel() }
        if subtitlePanel == nil { subtitlePanel = makeSubtitlePanel() }
        model.isBusy = false
        model.statusText = "Thinking…"
        model.level = 0.12
        model.levels = Array(repeating: 0.04, count: 11)
        smoothedLevel = 0.05
        model.partialText = ""
        positionPanel()
        panel?.orderFrontRegardless()
        subtitlePanel?.orderOut(nil)
        startMetering()
    }

    func showBusy(_ status: String = "Thinking…") {
        model.statusText = status
        model.isBusy = true
        stopMetering()
    }

    func showPartial(_ text: String) {
        guard liveCaptionsEnabled else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.partialText = value
        positionPanel()
        subtitlePanel?.orderFrontRegardless()
    }

    func hide() {
        stopMetering()
        panel?.orderOut(nil)
        subtitlePanel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let root = CompactRecorderView(model: model)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: root)
        panel.hidesOnDeactivate = false
        return panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 48
        )
        panel.setFrameOrigin(origin)
        if let subtitlePanel {
            subtitlePanel.setFrameOrigin(NSPoint(
                x: visible.midX - subtitlePanel.frame.width / 2,
                y: origin.y + panel.frame.height + 8
            ))
        }
    }

    private func makeSubtitlePanel() -> NSPanel {
        // Tall enough for the roomiest style (spatial-blur's stacked words,
        // terminal's boxed card); shorter styles just bottom-anchor their
        // content within this transparent area, so nothing looks broken.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: SubtitleBubbleView(model: model))
        panel.hidesOnDeactivate = false
        return panel
    }

    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let raw = max(0, min(1, self.meterProvider?() ?? 0))
                // Fast attack makes syllables visible; slower decay avoids
                // twitching while still settling between phrases.
                let response = raw > self.smoothedLevel ? 0.72 : 0.24
                self.smoothedLevel += (raw - self.smoothedLevel) * response
                self.model.level = max(0.035, min(1, self.smoothedLevel))
                self.model.levels.removeFirst()
                self.model.levels.append(self.model.level)
            }
        }
        if let meterTimer { RunLoop.main.add(meterTimer, forMode: .common) }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}

@MainActor
private final class RecorderHUDModel: ObservableObject {
    @Published var level: Double = 0.1
    @Published var levels = Array(repeating: 0.04, count: 11)
    @Published var isBusy = false
    @Published var statusText = "Thinking…"
    @Published var partialText = ""
    @Published var style: HUDStyle = .classicBars
    @Published var subtitleStyle: SubtitleStyle = .bubble
}

/// Chrome-free HUD: no cancel/finish buttons anywhere in any style -- Escape
/// cancels and the record hotkey finishes (both already work independently
/// of this view), so the floating indicator only ever shows the
/// visualization itself, matching how Siri's own indicator has no controls.
///
/// Live caption text is shown ONLY in the separate subtitle bubble panel
/// above this one (SubtitleBubbleView) -- it used to also repeat in a tiny
/// second copy inside this view, which just duplicated the same text twice
/// on screen at once.
private struct CompactRecorderView: View {
    @ObservedObject var model: RecorderHUDModel

    var body: some View {
        Group {
            if model.isBusy {
                Text(model.statusText)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                HUDVisualization(style: model.style, levels: model.levels)
            }
        }
        .frame(width: 64, height: 24)
        .padding(.horizontal, 8)
        .frame(width: 80, height: 36)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.055, green: 0.055, blue: 0.06).opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
        )
    }
}

struct HUDVisualization: View {
    let style: HUDStyle
    let levels: [Double]

    var body: some View {
        Group {
            switch style {
            case .classicBars:
                WaveformBars(levels: levels)
            case .siriOrb:
                SiriOrb(level: levels.last ?? 0)
            case .waterLine:
                WaterWave(levels: levels)
            case .minimalDots:
                MinimalDots(levels: levels)
            case .precisionWaveform:
                PrecisionWaveform(levels: levels)
            case .quantumOrb:
                QuantumOrb(level: levels.last ?? 0)
            case .minimalistRipple:
                MinimalistRipple(level: levels.last ?? 0)
            case .amberResonance:
                AmberResonance(level: levels.last ?? 0)
            case .pencilSketch:
                PencilSketch(level: levels.last ?? 0)
            case .zenIncense:
                ZenIncense(level: levels.last ?? 0)
            }
        }
        .frame(width: 64, height: 22)
    }
}

/// Jewel-tone palette from the reference design (green/purple), matching the
/// other two new styles below.
private enum JewelTone {
    static let green = Color(red: 0.447, green: 0.878, blue: 0.643)
    static let purple = Color(red: 0.659, green: 0.510, blue: 0.878)
}

/// "精準頻譜" (Precision Waveform): seven bars with a per-bar staggered
/// bounce, green/purple jewel tones, height also driven by real voice level.
private struct PrecisionWaveform: View {
    let levels: [Double]

    private static let colors: [Color] = [
        JewelTone.green, JewelTone.green, JewelTone.green,
        JewelTone.purple, JewelTone.purple,
        JewelTone.green, JewelTone.green,
    ]
    private static let baseHeights: [Double] = [0.2, 0.5, 0.8, 1.0, 0.8, 0.5, 0.2]
    private static let phaseOffsets: [Double] = [-0.4, -0.2, 0, -0.3, -0.1, -0.5, -0.2]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = levels.last ?? 0
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<7, id: \.self) { index in
                    let bounce = 0.5 + 0.5 * sin((t + Self.phaseOffsets[index]) * 6.3)
                    let energy = 0.3 + 0.7 * bounce
                    let magnitude = Self.baseHeights[index] * (0.3 + level * 0.9) * energy
                    Capsule()
                        .fill(Self.colors[index])
                        .frame(width: 2.4, height: max(2, 18 * magnitude))
                        .shadow(color: Self.colors[index].opacity(0.5), radius: 2)
                }
            }
        }
    }
}

/// "量子光球" (Quantum Orb): layered blurred glow rings (purple + green) with
/// a fast-pulsing white core, always gently alive and pushed further by
/// real voice level.
private struct QuantumOrb: View {
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let glow1 = 0.8 + 0.5 * sin(t * (2 * .pi / 2.0))
            let glow2 = 0.8 + 0.5 * sin(t * (2 * .pi / 1.5) + 1.0)
            let core = 0.85 + 0.25 * sin(t * (2 * .pi / 0.4))
            let energy = 0.5 + level * 0.8
            let size: CGFloat = 20

            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [JewelTone.purple.opacity(0.6), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.5
                    ))
                    .blur(radius: 3)
                    .scaleEffect(0.7 + glow1 * 0.35 * energy)
                Circle()
                    .fill(RadialGradient(
                        colors: [JewelTone.green.opacity(0.6), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.4
                    ))
                    .blur(radius: 2.5)
                    .scaleEffect(0.6 + glow2 * 0.3 * energy)
                Circle()
                    .fill(Color.white)
                    .frame(width: size * 0.24, height: size * 0.24)
                    .scaleEffect(core)
                    .shadow(color: .white, radius: 4)
            }
            .frame(width: size, height: size)
        }
    }
}

/// "極簡聲波" (Minimalist Ripple): concentric rings expanding outward from a
/// center dot on a staggered cycle, like a sonar ping.
private struct MinimalistRipple: View {
    let level: Double

    private static let delays: [Double] = [0, 0.5, 1.0, 1.5]
    private static let cycleDuration = 2.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let energy = 0.5 + level * 0.7
            ZStack {
                ForEach(Self.delays.indices, id: \.self) { index in
                    let localT = (t + Self.delays[index])
                        .truncatingRemainder(dividingBy: Self.cycleDuration) / Self.cycleDuration
                    let diameter = 4 + 18 * localT * energy
                    Circle()
                        .stroke(JewelTone.green, lineWidth: max(0.5, 3 * (1 - localT)))
                        .frame(width: diameter, height: diameter)
                        .opacity(max(0, 1 - localT))
                }
                Circle()
                    .fill(JewelTone.green)
                    .frame(width: 5, height: 5)
                    .shadow(color: JewelTone.green.opacity(0.5), radius: 2)
            }
        }
    }
}

/// Siri's own indicator is never static, even in silence -- it keeps a slow
/// idle breathing/rotation going and only grows more energetic with voice.
/// The previous version was driven purely by audio level, so during a quiet
/// moment (or before the meter had a sample) it visibly froze.
private struct SiriOrb: View {
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = 0.5 + 0.5 * sin(t * 1.7)
            let energy = 0.4 + level * 0.9
            let size = 15 + breathe * 4 + level * 7

            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.cyan, .blue, .purple, .pink, .orange, .cyan],
                            center: .center,
                            angle: .degrees(t * 60)
                        )
                    )
                    .blur(radius: 2.4)
                    .opacity(0.92)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.9), .white.opacity(0)],
                            center: UnitPoint(x: 0.4, y: 0.35),
                            startRadius: 0,
                            endRadius: size * 0.62
                        )
                    )
                    .scaleEffect(0.55 + energy * 0.22)
            }
            .frame(width: size, height: size)
            .shadow(color: .purple.opacity(0.5), radius: 3 + level * 5)
        }
    }
}

/// Port of the original flowing-waveform design (nexvoice_overlay.html,
/// the Hammerspoon-era HUD): three layered sine lines at different
/// frequencies/speeds/phases, tapered flat at both ends, with a gentle
/// always-alive floor so it's never a dead flat line even in silence.
private struct WaterWave: View {
    private struct Layer {
        let frequency: Double
        let speed: Double
        let phase: Double
        let amplitude: Double
        let width: CGFloat
        let color: Color
    }

    private static let layers: [Layer] = [
        Layer(frequency: 5.5, speed: 1.00, phase: 0.0, amplitude: 1.00, width: 2.0, color: .white.opacity(0.95)),
        Layer(frequency: 7.5, speed: -1.30, phase: 1.7, amplitude: 0.68, width: 1.4,
              color: Color(red: 0.84, green: 0.93, blue: 1.0).opacity(0.55)),
        Layer(frequency: 3.5, speed: 0.70, phase: 3.1, amplitude: 0.52, width: 1.2,
              color: Color(red: 0.63, green: 0.77, blue: 1.0).opacity(0.4)),
    ]

    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let voiceLevel = levels.last ?? 0
            let synthFloor = 0.05 + 0.05 * abs(sin(t * 0.8))
            let level = max(voiceLevel, synthFloor)

            Canvas { canvas, size in
                let centerY = size.height / 2
                let amplitude = (0.04 + level * 0.96) * size.height * 0.42
                let step: CGFloat = 2

                for layer in Self.layers {
                    var path = Path()
                    var x: CGFloat = 0
                    var first = true
                    while x <= size.width {
                        let u = Double(x / size.width)
                        let envelope = sin(u * .pi) // taper to flat at both ends
                        let y = centerY + amplitude * layer.amplitude * envelope
                            * sin(layer.frequency * u * .pi * 2 + t * layer.speed + layer.phase)
                        let point = CGPoint(x: x, y: y)
                        if first { path.move(to: point); first = false } else { path.addLine(to: point) }
                        x += step
                    }
                    canvas.stroke(
                        path,
                        with: .color(layer.color),
                        style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }
}

private struct MinimalDots: View {
    let levels: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                let source = levels.indices.contains(index * 2) ? levels[index * 2] : 0.05
                Circle()
                    .fill(.white.opacity(0.92))
                    .frame(width: 3.5 + source * 5, height: 3.5 + source * 5)
                    .animation(.easeOut(duration: 0.08), value: source)
            }
        }
    }
}

/// Dispatches to whichever caption visual treatment is selected in Settings.
/// `.bubble` is the original design and stays the default; the panel itself
/// is sized for the roomiest style (spatial-blur's stacked words) and every
/// style bottom-anchors its content so shorter styles sit right above the
/// HUD regardless of the extra transparent headroom.
private struct SubtitleBubbleView: View {
    @ObservedObject var model: RecorderHUDModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
        }
        .frame(width: 380, height: 130, alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        switch model.subtitleStyle {
        case .bubble:
            BubbleSubtitle(text: model.partialText)
        case .fluidGlow:
            FluidGlowSubtitle(text: model.partialText)
        case .teleprompter:
            TeleprompterSubtitle(text: model.partialText)
        case .terminal:
            TerminalSubtitle(text: model.partialText)
        case .spatialBlur:
            SpatialBlurSubtitle(text: model.partialText)
        }
    }
}

/// Settings-picker preview dispatcher: renders a given style against sample
/// text without needing the live HUD's shared RecorderHUDModel, the same
/// role HUDVisualization plays for the waveform/orb styles.
struct SubtitleStylePreview: View {
    let style: SubtitleStyle
    let text: String

    var body: some View {
        switch style {
        case .bubble: BubbleSubtitle(text: text)
        case .fluidGlow: FluidGlowSubtitle(text: text)
        case .teleprompter: TeleprompterSubtitle(text: text)
        case .terminal: TerminalSubtitle(text: text)
        case .spatialBlur: SpatialBlurSubtitle(text: text)
        }
    }
}

/// "膠囊字幕" (Bubble) -- the original design, kept as the default.
private struct BubbleSubtitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(maxWidth: 360, minHeight: 30)
            .background(.black.opacity(0.88), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }
}

/// "流動光暈" (Fluid Glow): the most-recently-received tail of characters
/// glows; earlier characters sit in a plain, dimmer white. Real ASR partials
/// don't come with per-character timing, so instead of animating a reveal,
/// this always highlights "the newest few characters of whatever we have
/// right now" -- capped to a bounded trailing window so very long partials
/// don't grow the panel unbounded.
private struct FluidGlowSubtitle: View {
    let text: String
    private static let visibleWindow = 26
    private static let activeTailCount = 4

    var body: some View {
        let characters = Array(text.suffix(Self.visibleWindow))
        let activeStart = max(0, characters.count - Self.activeTailCount)
        HStack(spacing: 0) {
            ForEach(characters.indices, id: \.self) { index in
                let isActive = index >= activeStart
                Text(String(characters[index]))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(isActive ? JewelTone.green : Color.white.opacity(0.85))
                    .shadow(color: isActive ? JewelTone.green.opacity(0.7) : .clear, radius: isActive ? 6 : 0)
                    .scaleEffect(isActive ? 1.05 : 1.0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 360, minHeight: 30)
        .background(.black.opacity(0.75), in: Capsule())
    }
}

/// "提詞機" (Teleprompter): bold, wide letter-spacing, high-contrast --
/// there's no "not yet spoken" preview to dim (real ASR doesn't know future
/// words), so this is purely a typographic variant on the current text.
private struct TeleprompterSubtitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 14)
            .frame(maxWidth: 360, minHeight: 32)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "終端機打字" (Terminal): monospaced text in a dark card with a blinking
/// cursor block, evoking a live typing terminal.
private struct TerminalSubtitle: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.4)) { context in
            let blinkOn = Int(context.date.timeIntervalSinceReferenceDate / 0.4).isMultiple(of: 2)
            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(1)
                    .truncationMode(.head)
                Rectangle()
                    .fill(JewelTone.green)
                    .frame(width: 7, height: 15)
                    .opacity(blinkOn ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(Color(white: 0.094), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

/// "空間焦距模糊" (Spatial Blur): the last few tokens of the current partial
/// text stacked vertically, newest at the bottom (closest to the HUD, in
/// focus) and older ones progressively higher, smaller, blurrier, and
/// fainter -- approximating the reference's word-cascade for text that
/// arrives as whole-string updates rather than a scripted word-by-word feed.
private struct SpatialBlurSubtitle: View {
    let text: String

    private struct Depth {
        let fontSize: CGFloat
        let color: Color
        let blur: CGFloat
        let opacity: Double
    }

    var body: some View {
        let recent = Array(Self.tokenize(text).suffix(4))
        VStack(spacing: 6) {
            ForEach(recent.indices, id: \.self) { index in
                let distanceFromNewest = recent.count - 1 - index
                let depth = Self.style(forDepth: distanceFromNewest)
                Text(recent[index])
                    .font(.system(size: depth.fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(depth.color)
                    .blur(radius: depth.blur)
                    .opacity(depth.opacity)
            }
        }
        .frame(maxWidth: 360)
    }

    private static func style(forDepth depth: Int) -> Depth {
        switch depth {
        case 0: Depth(fontSize: 16, color: .white, blur: 0, opacity: 1)
        case 1: Depth(fontSize: 13, color: .white.opacity(0.7), blur: 1, opacity: 0.55)
        case 2: Depth(fontSize: 11, color: .white.opacity(0.4), blur: 2, opacity: 0.2)
        default: Depth(fontSize: 10, color: .white.opacity(0.2), blur: 3, opacity: 0.08)
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        let whitespaceSplit = text.split(separator: " ").map(String.init)
        if whitespaceSplit.count > 1 { return whitespaceSplit }
        // Real ASR partials for CJK text rarely have whitespace to split on;
        // fall back to fixed-length chunks so there's still something to stack.
        let characters = Array(text)
        let chunkSize = 4
        return stride(from: 0, to: characters.count, by: chunkSize).map { start in
            String(characters[start..<min(start + chunkSize, characters.count)])
        }
    }
}

private struct WaveformBars: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let emphasis = 0.82 + 0.18 * sin(Double(index) * 0.8)
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2, height: 3.5 + 18 * min(1, level * emphasis))
                    .animation(.linear(duration: 0.075), value: level)
            }
        }
    }
}

/// "木質暖香" (Amber Resonance): two overlapping warm-amber blurred blobs
/// that slowly rotate and breathe scale in opposite directions, evoking a
/// candlelit/organic glow rather than a hard-edged orb.
private struct AmberResonance: View {
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let energy = 0.5 + level * 0.7
            ZStack {
                blob(t: t, period: 4, reversed: false, colors: [
                    Color(red: 0.851, green: 0.451, blue: 0.204),
                    Color(red: 0.549, green: 0.227, blue: 0.086),
                ], size: 20, opacity: 1)
                blob(t: t, period: 3, reversed: true, colors: [
                    Color(red: 0.902, green: 0.667, blue: 0.408),
                    Color(red: 0.651, green: 0.353, blue: 0.180),
                ], size: 15, opacity: 0.8)
            }
            .scaleEffect(energy)
        }
    }

    private func blob(t: Double, period: Double, reversed: Bool, colors: [Color], size: CGFloat, opacity: Double) -> some View {
        let direction = reversed ? -1.0 : 1.0
        let cycle = (t / period).truncatingRemainder(dividingBy: 1)
        let rotation = Angle(degrees: direction * cycle * 360)
        let scale = 0.9 + 0.2 * sin(cycle * 2 * .pi)
        return Circle()
            .fill(RadialGradient(colors: colors + [.clear], center: .center, startRadius: 0, endRadius: size * 0.5))
            .frame(width: size, height: size)
            .blur(radius: 3)
            .rotationEffect(rotation)
            .scaleEffect(scale)
            .opacity(opacity)
            .blendMode(.screen)
    }
}

/// "優雅素描" (Pencil Sketch): three partial-arc rings, each rotating at a
/// different speed/direction, evoking a pen continuously re-tracing loose
/// circles -- an ink-sketch-style "thinking" spinner rather than a literal
/// voice-level meter.
private struct PencilSketch: View {
    let level: Double

    private struct Ring {
        let trim: Double
        let period: Double
        let reversed: Bool
        let color: Color
        let lineWidth: CGFloat
        let opacity: Double
        let scale: CGFloat
    }

    private static let rings: [Ring] = [
        Ring(trim: 0.78, period: 2.5, reversed: false, color: .white.opacity(0.9), lineWidth: 1.4, opacity: 0.9, scale: 0.95),
        Ring(trim: 0.7, period: 3.5, reversed: true, color: Color(red: 0.231, green: 0.510, blue: 0.965).opacity(0.75), lineWidth: 1.2, opacity: 0.6, scale: 1.0),
        Ring(trim: 0.85, period: 2.0, reversed: false, color: .white.opacity(0.6), lineWidth: 1.0, opacity: 0.3, scale: 1.05),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let size: CGFloat = 20 + level * 2
            ZStack {
                ForEach(Self.rings.indices, id: \.self) { index in
                    let ring = Self.rings[index]
                    let direction = ring.reversed ? -1.0 : 1.0
                    let cycle = (t / ring.period).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .trim(from: 0, to: ring.trim)
                        .stroke(ring.color, style: StrokeStyle(lineWidth: ring.lineWidth, lineCap: .round))
                        .frame(width: size * ring.scale, height: size * ring.scale)
                        .rotationEffect(.degrees(direction * cycle * 360))
                        .opacity(ring.opacity)
                }
            }
        }
    }
}

/// "裊裊輕煙" (Zen Incense): a small ember dot with soft wisps of smoke
/// drifting upward, scaling and fading out, staggered on a shared cycle.
private struct ZenIncense: View {
    let level: Double

    private static let emberColor = Color(red: 0.925, green: 0.369, blue: 0.157)
    private static let delays: [Double] = [0, 1.3, 2.6]
    private static let cycleDuration = 4.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let energy = 0.6 + level * 0.6
            ZStack(alignment: .bottom) {
                ForEach(Self.delays.indices, id: \.self) { index in
                    let localT = (t + Self.delays[index])
                        .truncatingRemainder(dividingBy: Self.cycleDuration) / Self.cycleDuration
                    let riseHeight = 14 * localT * energy
                    let driftX = (index.isMultiple(of: 2) ? 1.0 : -1.0) * 4 * localT
                    let wisp = Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [Self.emberColor.opacity(0.7), .white.opacity(0.25), .clear],
                                startPoint: .bottom, endPoint: .top
                            )
                        )
                        .frame(width: 4 + localT * 4, height: 10)
                        .blur(radius: 2 + localT * 3)
                        .opacity(localT < 0.15 ? localT / 0.15 : max(0, 1 - localT))
                    wisp
                        .offset(x: driftX, y: -riseHeight)
                }
                Circle()
                    .fill(Self.emberColor)
                    .frame(width: 4, height: 4)
                    .shadow(color: Self.emberColor.opacity(0.6), radius: 2)
            }
            .frame(width: 20, height: 22, alignment: .bottom)
        }
    }
}
