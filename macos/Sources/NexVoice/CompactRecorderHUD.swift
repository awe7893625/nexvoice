import AppKit
import SwiftUI

@MainActor
final class CompactRecorderHUD {
    private var panel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var meterTimer: Timer?
    private var smoothedLevel = 0.05
    /// Strips room tone before the HUD sees a level -- see HUDNoiseGate.
    /// Deliberately *not* reset between recordings: the estimate is only ever
    /// as good as the quiet it has heard, and a fresh gate starts by trusting
    /// the first 2.5s unconditionally.
    private var noiseGate = HUDNoiseGate()
    /// Preview feeds a synthetic envelope that is already clean. It has no
    /// syllable gaps, so min-hold would read its falling half as room tone and
    /// clip it -- the preview would stall for seconds at a time.
    var bypassNoiseGate = false
    private var historyTick = 0
    private let model = RecorderHUDModel()
    private var liveCaptionsEnabled = true
    var meterProvider: (() -> Double)?

    func configure(style: HUDStyle, chrome: HUDChrome, liveCaptionsEnabled: Bool, subtitleStyle: SubtitleStyle) {
        model.style = style
        model.chrome = chrome
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
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
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
                y: origin.y + panel.frame.height - 14
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
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: SubtitleBubbleView(model: model))
        panel.hidesOnDeactivate = false
        return panel
    }

    private func startMetering() {
        stopMetering()
        // 25 Hz: the animation phase is integrated on every tick so motion
        // stays smooth, while the level history still advances every other
        // tick to keep its original 0.08s cadence.
        let interval = 0.04
        historyTick = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let raw = self.meterProvider?() ?? 0
                let voiced = self.bypassNoiseGate
                    ? (raw.isNaN ? 0 : max(0, min(1, raw)))
                    : self.noiseGate.voiced(raw: raw)

                // Fast attack makes syllables visible; slower decay avoids
                // twitching while still settling between phrases.
                let response = voiced > self.smoothedLevel ? 0.72 : 0.24
                self.smoothedLevel += (voiced - self.smoothedLevel) * response
                let level = max(0, min(1, self.smoothedLevel))
                self.model.level = level
                self.model.phase += interval * nexVoiceHUDMotionRate(level: level)

                self.historyTick += 1
                if self.historyTick.isMultiple(of: 2) {
                    self.model.levels.removeFirst()
                    self.model.levels.append(max(0.035, level))
                }
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
    /// Voice-integrated animation phase handed to every style via
    /// `\.hudPhase`; advances fast while speaking, barely at all in silence.
    @Published var phase: Double = 0
    @Published var isBusy = false
    @Published var statusText = "Thinking…"
    @Published var partialText = ""
    @Published var style: HUDStyle = .glass
    @Published var chrome: HUDChrome = .borderless
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
            if model.chrome == .naked {
                nakedContent
            } else {
                platedContent
            }
        }
        .frame(width: 148, height: 80)
        .environment(\.hudPhase, model.phase)
    }

    @ViewBuilder private var platedContent: some View {
        Group {
            if model.isBusy {
                Text(model.statusText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                HUDVisualization(style: model.style, levels: model.levels)
            }
        }
        .frame(width: 78, height: 26)
        .frame(width: 100, height: 40)
        .background(HUDCapsuleChrome(chrome: model.chrome, busy: model.isBusy))
    }

    /// Siri-style free-floating mode: no plate at all, visualization scaled up.
    @ViewBuilder private var nakedContent: some View {
        if model.isBusy {
            Text(model.statusText)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.95))
                .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
                .lineLimit(1)
        } else {
            HUDVisualization(style: model.style, levels: model.levels)
                .scaleEffect(2.0)
                .shadow(color: .black.opacity(0.30), radius: 7, y: 3)
        }
    }
}

/// Faithful port of the ChatGPT "純黑玻璃" reference: ~27 rounded luminous
/// white bars with bloom, heights mixing live level, per-bar phase motion
/// and a center-weighted envelope so the cluster breathes like Siri's.
private struct GlassBars: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let barCount = 23

    var body: some View {
        let t = hudPhase
        let level = levels.last ?? 0
        let energy = 0.22 + min(1, level) * 0.78
        HStack(alignment: .center, spacing: 1.3) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                let u = Double(index) / Double(Self.barCount - 1)
                // Center-weighted, with two side lobes so it's not a plain hill.
                let envelope = 0.30 + 0.70 * pow(sin(u * .pi), 1.4)
                    + 0.18 * sin(u * .pi * 3.1)
                let wobble = 0.5 + 0.5 * sin(t * 2.4 + Double(index) * 0.9)
                    * sin(t * 1.1 + Double(index) * 0.35)
                let h = max(0.10, envelope * (0.28 + 0.72 * wobble) * energy)
                Capsule()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: 2.2, height: max(3.0, 24 * h))
                    .shadow(color: .white.opacity(0.9), radius: 2.6)
                    .shadow(color: .white.opacity(0.4), radius: 6)
            }
        }
    }
}

/// Obsidian base shared by all chromes; each case layers its own frame on top.
struct HUDCapsuleChrome: View {
    let chrome: HUDChrome
    var busy: Bool = false

    private var base: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.10, blue: 0.115),
                        Color(red: 0.045, green: 0.045, blue: 0.055),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.13), location: 0),
                                .init(color: .white.opacity(0.04), location: 0.38),
                                .init(color: .clear, location: 0.55),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(1)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    /// Warmer, metallic base used by `.emboss` -- colors lifted from the
    /// pack-B mockup's 浮雕 variant `drawEmboss()` glass fill.
    private var embossBase: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.333, green: 0.322, blue: 0.298),
                        Color(red: 0.122, green: 0.118, blue: 0.110),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.13), location: 0),
                                .init(color: .white.opacity(0.04), location: 0.38),
                                .init(color: .clear, location: 0.55),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(1)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    /// Wraparound-safe trim segment: draws `length` of the capsule's
    /// perimeter starting at `start` (both in the 0...1 trim space),
    /// splitting into two trims when the segment crosses the 1 -> 0 seam.
    @ViewBuilder
    private func scanSegment(from start: Double, length: Double, opacity: Double, lineWidth: Double) -> some View {
        let end = start + length
        if end <= 1 {
            Capsule()
                .trim(from: start, to: end)
                .stroke(Color.white.opacity(opacity), lineWidth: lineWidth)
        } else {
            ZStack {
                Capsule()
                    .trim(from: start, to: 1)
                    .stroke(Color.white.opacity(opacity), lineWidth: lineWidth)
                Capsule()
                    .trim(from: 0, to: end - 1)
                    .stroke(Color.white.opacity(opacity), lineWidth: lineWidth)
            }
        }
    }

    private func wrapped01(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    var body: some View {
        switch chrome {
        case .borderless:
            base
        case .hairline:
            base.overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
        case .glowEdge:
            base.overlay {
                TimelineView(.animation(minimumInterval: 0.05)) { context in
                    let t = nexVoiceHUDTime(context.date)
                    Capsule()
                        .strokeBorder(
                            AngularGradient(
                                colors: [
                                    Color(red: 0.494, green: 0.91, blue: 0.839),
                                    Color(red: 0.592, green: 0.541, blue: 1.0),
                                    Color(red: 1.0, green: 0.549, blue: 0.835),
                                    Color(red: 0.494, green: 0.91, blue: 0.839),
                                ],
                                center: .center,
                                angle: .degrees(t * 40)
                            ),
                            lineWidth: 1.2
                        )
                        .opacity(0.85)
                        .shadow(color: Color(red: 0.592, green: 0.541, blue: 1.0).opacity(0.35), radius: 6)
                }
            }
        case .breathingRing:
            base.overlay {
                TimelineView(.animation(minimumInterval: 0.05)) { context in
                    let t = nexVoiceHUDTime(context.date)
                    if busy {
                        // Clockwise scan light, mirroring the pack-B mockup's
                        // 呼吸 variant thinking-state sweep: head speed 0.22
                        // turns/sec, ~0.18 of the perimeter lit, brightest at
                        // the leading edge and fading through a dim tail.
                        let head = wrapped01(t * 0.22)
                        let tailStart = wrapped01(head - 0.18)
                        ZStack {
                            scanSegment(from: tailStart, length: 0.12, opacity: 0.18, lineWidth: 1.2)
                            scanSegment(from: head, length: 0.06, opacity: 0.5, lineWidth: 1.2)
                                .shadow(color: .white.opacity(0.3), radius: 3)
                        }
                    } else {
                        let breathe = 0.5 + 0.5 * sin(t * 1.6)
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.10 + 0.22 * breathe), lineWidth: 1)
                            .shadow(color: .white.opacity(0.12 * breathe), radius: 5)
                    }
                }
            }
        case .naked:
            Color.clear
        case .aura:
            TimelineView(.animation(minimumInterval: 0.05)) { context in
                let t = nexVoiceHUDTime(context.date)
                let breathe = 0.5 + 0.5 * sin(t * 1.4)
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.494, green: 0.91, blue: 0.839),
                                    Color(red: 0.592, green: 0.541, blue: 1.0),
                                    Color(red: 1.0, green: 0.549, blue: 0.835),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .blur(radius: 10)
                        .opacity(0.45 + 0.2 * breathe)
                        .scaleEffect(1.06)
                    base
                }
            }
        case .emboss:
            embossBase.overlay {
                ZStack {
                    Capsule()
                        .strokeBorder(Color.black.opacity(0.5), lineWidth: 0.75)
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                        .padding(1.5)
                }
            }
        }
    }
}

struct HUDVisualization: View {
    let style: HUDStyle
    let levels: [Double]

    var body: some View {
        Group {
            switch style {
            case .glassBars:
                GlassBars(levels: levels)
            case .bloomPills:
                BloomPills(levels: levels)
            case .plasmaColumns:
                PlasmaColumns(levels: levels)
            case .liquidPulse:
                LiquidPulse(levels: levels)
            case .auraRibbon:
                GlowRibbon(levels: levels)
            case .glass:
                WaterWave(levels: levels)
            case .aurora:
                AuroraBars(levels: levels)
            case .siri:
                DepthOrb(level: levels.last ?? 0)
            case .prismCore:
                IrisCore(levels: levels)
            case .ember:
                EmberBars(levels: levels)
            case .comet:
                CometStream(levels: levels)
            case .helix:
                HelixBraid(levels: levels)
            case .mercury:
                MercuryBand(levels: levels)
            case .plasma:
                PlasmaArc(levels: levels)
            case .eclipse:
                EclipseCorona(levels: levels)
            case .smoke:
                SmokePlume(levels: levels)
            case .horizontalSmoke:
                HorizontalSmoke(levels: levels)
            case .oceanSwell:
                OceanSwell(levels: levels)
            case .silkStream:
                SilkStream(levels: levels)
            case .auroraMist:
                AuroraMist(levels: levels)
            case .inkBloom:
                InkBloom(levels: levels)
            }
        }
        .frame(width: 64, height: 22)
    }
}

/// Port of the original flowing-waveform design (nexvoice_overlay.html,
/// the Hammerspoon-era HUD): three layered sine lines at different
/// frequencies/speeds/phases, tapered flat at both ends, with a gentle
/// always-alive floor so it's never a dead flat line even in silence.
private struct WaterWave: View {
    @Environment(\.hudPhase) private var hudPhase
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
        let t = hudPhase
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
        .padding(.bottom, 10)
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
            .padding(.horizontal, 14)
            .frame(maxWidth: 360, minHeight: 30)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.115, green: 0.115, blue: 0.13).opacity(0.94),
                                Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.94),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(0.3), radius: 7, y: 2)
            )
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
                    .foregroundStyle(isActive ? Color(red: 0.447, green: 0.878, blue: 0.643) : Color.white.opacity(0.85))
                    .shadow(color: isActive ? Color(red: 0.447, green: 0.878, blue: 0.643).opacity(0.7) : .clear, radius: isActive ? 6 : 0)
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
            let blinkOn = Int(nexVoiceHUDTime(context.date) / 0.4).isMultiple(of: 2)
            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(1)
                    .truncationMode(.head)
                Rectangle()
                    .fill(Color(red: 0.447, green: 0.878, blue: 0.643))
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

/// Deterministic hash used by the ports below (赤霞) -- mirrors the
/// ChatGPT HUD-pack mockup's `seeded(n)` so particle/crystal positions are
/// stable across frames instead of flickering like Double.random would.
private func nexVoiceSeeded(_ seed: Double) -> Double {
    abs(sin(seed * 12.9898 + 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
}

/// Shared multi-harmonic wave path used by 浮聲/脈界/霜息/赤霞 -- ports the
/// mockup's `drawSmoothWave` helper (three summed sine terms tapered to flat
/// at both ends) so each variant only supplies its own color/amplitude/frequency/phase.
private func nexVoiceSmoothWavePath(size: CGSize, t: Double, energy: Double, amplitude: Double, frequency: Double, phase: Double) -> Path {
    var path = Path()
    let centerY = size.height / 2
    let start = size.width * 0.1
    let span = size.width * 0.8
    let breath = 0.1 + energy * 0.9
    for i in 0...60 {
        let p = Double(i) / 60
        let envelope = pow(sin(p * .pi), 0.72)
        let wave = sin(p * .pi * frequency + t * 2.7 + phase) * 0.64
            + sin(p * .pi * (frequency * 1.87) - t * 1.9 + phase * 0.7) * 0.24
            + sin(p * .pi * 0.8 + t * 0.8) * 0.12
        let y = centerY + wave * amplitude * envelope * breath
        let x = start + CGFloat(p) * span
        let point = CGPoint(x: x, y: y)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

/// Animation clock for the capsule chrome and the caption cursor only --
/// frame shimmer and the "thinking" sweep report processing, not speech, so
/// they stay on the wall clock. Every waveform style instead reads
/// `\.hudPhase`, which only advances when there is something to hear.
///
/// Do NOT convert the remaining callers to `hudPhase`: a "thinking" sweep that
/// freezes while the transcript is being computed reads as a hang.
private func nexVoiceHUDTime(_ date: Date) -> Double {
    date.timeIntervalSinceReferenceDate * 0.55
}

/// How fast a HUD's animation phase advances at a given voice level.
///
/// Previously every style ran off the wall clock, so scans swept, comets
/// cruised and bars wobbled at exactly the same speed whether you were
/// talking or the room was silent -- the level only scaled amplitude. Motion
/// now comes from the voice: near-still when quiet, lively when loud. Kept
/// linear in `level` so the settings previews can integrate it in closed form.
func nexVoiceHUDMotionRate(level: Double) -> Double {
    0.10 + 1.35 * min(1, max(0, level))
}

/// Synthetic (level, phase) pair for the settings previews, which have no
/// microphone. Uses the very same motion law fed by a breathing envelope, so
/// a tile in the grid demonstrates how that style will actually behave --
/// slowing as the breath falls, quickening as it rises.
///
/// `phase` is the analytic integral of `nexVoiceHUDMotionRate` over
/// `level(t) = 0.5 + 0.5·sin(wt)`, so no timer state is needed and the
/// result is monotonic (its derivative bottoms out at the 0.10 idle rate).
func nexVoiceHUDPreviewSignal(at time: Double) -> (level: Double, phase: Double) {
    let w = 0.55
    let level = 0.5 + 0.5 * sin(time * w)
    let phase = 0.775 * time - (0.675 / w) * cos(time * w)
    return (level, phase)
}

private struct HUDPhaseKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

extension EnvironmentValues {
    /// Voice-integrated animation phase, in the same units the styles used to
    /// get from the wall clock.
    var hudPhase: Double {
        get { self[HUDPhaseKey.self] }
        set { self[HUDPhaseKey.self] = newValue }
    }
}

// MARK: - Design-lane ports (Gemini HUD gallery, 2026-07-25)
//
// Four variants designed against the voice-phase contract rather than adapted
// to it afterwards: their draw functions take `(level, levelHistory, phase)`
// and nothing else, so silence really is still. Geometry constants come from
// the prototype's 156x52 canvas and are scaled by `plate`, which keeps them
// faithful at the 64x22 plated size and at 2x in naked mode.

/// Reference width of the prototype canvas these ports were drawn against.
private let nexVoiceHUDReferenceWidth: Double = 156

/// "膠囊光暈" -- seven wide round-capped pills with a bloom halo, the closest
/// thing in the pack to the ChatGPT reference approved design, but with far
/// fewer, fatter bars so it keeps its weight at HUD size.
private struct BloomPills: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let barCount = 7

    var body: some View {
        Canvas { canvas, size in
            let plate = Double(size.width) / nexVoiceHUDReferenceWidth
            let level = levels.last ?? 0
            let barWidth = 6.0 * plate
            let spacing = 8.0 * plate
            let centerY = Double(size.height) / 2
            let span = Double(Self.barCount) * barWidth + Double(Self.barCount - 1) * spacing
            let startX = (Double(size.width) - span) / 2
            let minHeight = 6.0 * plate
            let maxHeight = Double(size.height) * 0.75

            var pills = Path()
            for index in 0..<Self.barCount {
                let mid = Double(Self.barCount - 1) / 2
                let centerDist = abs(Double(index) - mid) / mid
                let weight = cos(centerDist * .pi * 0.4)
                let wave = sin(hudPhase * 2.5 + Double(index) * 0.75) * 0.3 + 0.7
                let history = levels[index % levels.count]
                let energy = level * 0.7 + history * 0.3
                let height = max(minHeight, energy * maxHeight * weight * wave + minHeight)
                let x = startX + Double(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
                pills.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
            }

            // Bloom first, as a blurred copy underneath the crisp pills.
            canvas.drawLayer { layer in
                layer.addFilter(.blur(radius: (2 + level * 5) * plate))
                layer.fill(pills, with: .color(.white.opacity(0.25 + level * 0.55)))
            }
            canvas.fill(pills, with: .color(.white.opacity(0.85 + level * 0.15)))
        }
    }
}

/// "等離子柱" -- eleven slim columns under a Gaussian centre weight, each with
/// a bright core fading at both ends, so the cluster reads as one lit object
/// rather than a row of ticks.
private struct PlasmaColumns: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let barCount = 11

    var body: some View {
        Canvas { canvas, size in
            let plate = Double(size.width) / nexVoiceHUDReferenceWidth
            let level = levels.last ?? 0
            let barWidth = 4.0 * plate
            let spacing = 6.0 * plate
            let height = Double(size.height)
            let centerY = height / 2
            let span = Double(Self.barCount) * barWidth + Double(Self.barCount - 1) * spacing
            let startX = (Double(size.width) - span) / 2
            let core = Gradient(colors: [
                .white.opacity(0.4),
                .white.opacity(0.9 + level * 0.1),
                .white.opacity(0.4),
            ])

            var glow = Path()
            for index in 0..<Self.barCount {
                let mid = Double(Self.barCount - 1) / 2
                let centerDist = abs(Double(index) - mid) / mid
                let weight = exp(-centerDist * centerDist * 2.5)
                let wave = sin(hudPhase * 3.0 + Double(index) * 0.6) * 0.2 + 0.8
                let history = levels[index % levels.count]
                let energy = level * 0.8 + history * 0.2
                let barHeight = energy * (height * 0.7) * weight * wave + 4 * plate
                let x = startX + Double(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: centerY - barHeight / 2, width: barWidth, height: barHeight)
                var column = Path()
                column.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                glow.addPath(column)
                canvas.fill(
                    column,
                    with: .linearGradient(
                        core,
                        startPoint: CGPoint(x: 0, y: rect.minY),
                        endPoint: CGPoint(x: 0, y: rect.maxY)
                    )
                )
            }

            canvas.drawLayer { layer in
                layer.addFilter(.blur(radius: (1.5 + level * 4) * plate))
                layer.fill(glow, with: .color(.white.opacity(0.30 + level * 0.35)))
            }
        }
    }
}

/// "液態脈衝" -- nineteen fine columns under a cosine window, dense enough to
/// read as a continuous body of light that thickens with the voice.
private struct LiquidPulse: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let barCount = 19

    var body: some View {
        Canvas { canvas, size in
            let plate = Double(size.width) / nexVoiceHUDReferenceWidth
            let level = levels.last ?? 0
            let barWidth = 3.0 * plate
            let spacing = 4.0 * plate
            let height = Double(size.height)
            let centerY = height / 2
            let span = Double(Self.barCount) * barWidth + Double(Self.barCount - 1) * spacing
            let startX = (Double(size.width) - span) / 2

            var bright = Path()
            for index in 0..<Self.barCount {
                let norm = (Double(index) - Double(Self.barCount) / 2) / (Double(Self.barCount) / 2)
                let window = cos(norm * .pi * 0.48)
                let sway = sin(hudPhase * 2.2 + Double(index) * 0.4)
                let history = levels[index % levels.count]
                let energy = level * 0.85 + history * 0.15
                let barHeight = max(4 * plate, energy * (height * 0.72) * window * (0.7 + sway * 0.3) + 4 * plate)
                let x = startX + Double(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: centerY - barHeight / 2, width: barWidth, height: barHeight)
                var column = Path()
                column.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                bright.addPath(column)
                canvas.fill(column, with: .color(.white.opacity(0.5 + level * 0.5 * window)))
            }

            if level > 0.3 {
                canvas.drawLayer { layer in
                    layer.addFilter(.blur(radius: (level - 0.3) * 6 * plate))
                    layer.fill(bright, with: .color(.white.opacity(0.45)))
                }
            }
        }
    }
}

/// "極光絲帶" -- two mirrored translucent ribbons tapered at both ends, the
/// pack's answer to a waveform with no frame and no hard edges.
private struct GlowRibbon: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let points = 16

    var body: some View {
        Canvas { canvas, size in
            let plate = Double(size.width) / nexVoiceHUDReferenceWidth
            let level = levels.last ?? 0
            let width = Double(size.width)
            let height = Double(size.height)
            let centerY = height / 2
            let step = width / Double(Self.points - 1)

            for layer in 0..<2 {
                let foreground = layer == 1
                let direction: Double = foreground ? 1 : -0.7
                let amplitude = (4 * plate + level * (height * 0.38))
                var ribbon = Path()
                ribbon.move(to: CGPoint(x: 0, y: centerY))

                for index in 0..<Self.points {
                    let x = Double(index) * step
                    let norm = (x / width - 0.5) * 2
                    let taper = cos(norm * .pi * 0.45)
                    let first = sin(hudPhase * 2.0 * direction + Double(index) * 0.5)
                    let second = cos(hudPhase * 3.2 * direction - Double(index) * 0.3)
                    let offset = (first + second * 0.5) * (amplitude * taper / 1.5)
                    let y = centerY + (foreground ? offset : -offset)
                    if index == 0 {
                        ribbon.move(to: CGPoint(x: x, y: y))
                    } else {
                        let previousX = Double(index - 1) * step
                        ribbon.addQuadCurve(
                            to: CGPoint(x: (previousX + x) / 2, y: y),
                            control: CGPoint(x: previousX, y: y)
                        )
                    }
                }
                ribbon.addLine(to: CGPoint(x: width, y: centerY))
                ribbon.addLine(to: CGPoint(x: 0, y: centerY))
                ribbon.closeSubpath()

                let alpha = foreground ? (0.6 + level * 0.4) : (0.25 + level * 0.35)
                canvas.drawLayer { blurred in
                    blurred.addFilter(.blur(radius: (foreground ? 3 + level * 5 : 1) * plate))
                    blurred.fill(ribbon, with: .color(.white.opacity(alpha * 0.7)))
                }
                canvas.fill(ribbon, with: .color(.white.opacity(alpha)))
            }
        }
    }
}
