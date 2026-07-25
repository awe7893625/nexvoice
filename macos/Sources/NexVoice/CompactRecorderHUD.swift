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
    let levels: [Double]

    private static let barCount = 23

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04)) { context in
            let t = nexVoiceHUDTime(context.date)
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
            case .glass:
                WaterWave(levels: levels)
            case .ink:
                InkStroke(levels: levels)
            case .aurora:
                AuroraRibbon(levels: levels)
            case .siri:
                SiriOrb(level: levels.last ?? 0)
            case .spectrum:
                PrecisionWaveform(levels: levels)
            case .floatVoice:
                FloatVoice(levels: levels)
            case .prismCore:
                PrismCore(levels: levels)
            case .ember:
                Ember(levels: levels)
            case .comet:
                CometTrail(levels: levels)
            case .helix:
                Helix(levels: levels)
            case .mercury:
                Mercury(levels: levels)
            case .ekg:
                EKG(levels: levels)
            case .meteor:
                MeteorShower(levels: levels)
            case .plasma:
                Plasma(levels: levels)
            case .silk:
                Silk(levels: levels)
            case .cascade:
                Cascade(levels: levels)
            case .eclipse:
                Eclipse(levels: levels)
            }
        }
        .frame(width: 64, height: 22)
    }
}

/// “墨韻” (ink) —— 宣紙邊上呼吸的一筆墨：暖米紙半透明卡、單筆變寬墨帶。
private struct InkStroke: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = nexVoiceHUDTime(context.date)
            let maxLevel = levels.max() ?? 0
            let baseThickness = 2.2
            let thicknessVariation = 0.62
            
            Canvas { canvas, size in
                let centerY = size.height / 2
                let step: CGFloat = 8
                var prevPoint: CGPoint?
                
                for x in stride(from: 0, through: size.width, by: step) {
                    let u = x / size.width
                    let envelope = sin(u * .pi)
                    let drift = maxLevel * 0.55 * envelope * sin(4.2 * u * .pi * 2 + t * 0.9)
                    let thickness = baseThickness + maxLevel * thicknessVariation * envelope * (
                        0.55 + 0.45 * sin(6.8 * u * .pi * 2 - t * 1.25)
                    )
                    
                    let y = centerY + drift
                    
                    if let prevPoint {
                        canvas.stroke(
                            Path { path in
                                path.move(to: prevPoint)
                                path.addLine(to: CGPoint(x: x, y: y))
                            },
                            with: .color(Color(red: 0.96, green: 0.93, blue: 0.86).opacity(0.95)),
                            style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                        )
                    }
                    
                    prevPoint = CGPoint(x: x, y: y)
                }
                
                // Dry-brush echo
                if let prevPoint {
                    canvas.stroke(
                        Path { path in
                            path.move(to: prevPoint)
                            for x in stride(from: size.width, through: 0, by: -step) {
                                let u = x / size.width
                                let envelope = sin(u * .pi)
                                let y = centerY + maxLevel * 0.55 * envelope * sin(4.2 * u * .pi * 2 + t * 0.9) - (3.5 + maxLevel * 0.22 * envelope)
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        },
                        with: .color(Color(red: 0.96, green: 0.93, blue: 0.86).opacity(0.28)),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round)
                    )
                }
            }
        }
    }
}

/// “極光” (aurora) —— 極夜天空下的一條光帶：近黑深藍玻璃、青→紫→洋紅漸層絲帶波形。
private struct AuroraRibbon: View {
    let levels: [Double]

    private static let gradientColors: [Color] = [
        Color(red: 0.494, green: 0.91, blue: 0.839), // teal
        Color(red: 0.592, green: 0.541, blue: 1.0),   // violet
        Color(red: 1.0, green: 0.549, blue: 0.835)    // magenta
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { (context: TimelineViewDefaultContext) in
            auroraCanvas(t: nexVoiceHUDTime(context.date))
        }
    }

    private func auroraCanvas(t: Double) -> some View {
        let maxLevel = levels.max() ?? 0
        let synthFloor = 0.05 + 0.05 * abs(sin(t * 0.8))
        let level = max(maxLevel, synthFloor)
        let amplitude = (0.04 + level * 0.96) * 20
        return Canvas { canvas, size in
            let centerY = size.height / 2
            for layerIndex in 0..<3 {
                let frequency = 5.0 + Double(layerIndex) * 1.0
                let speed = 0.95 + Double(layerIndex) * 0.1
                let phase = Double(layerIndex) * 2.0
                let amplitudeFactor = 1.0 - Double(layerIndex) * 0.3
                var path = Path()
                let step: CGFloat = 6
                var first = true
                var x: CGFloat = 0
                while x <= size.width {
                    let u = Double(x / size.width)
                    let envelope = sin(u * .pi)
                    let y = centerY + amplitude * amplitudeFactor * envelope *
                        sin(frequency * u * .pi * 2 + t * speed + phase)
                    let point = CGPoint(x: x, y: y)
                    if first { path.move(to: point); first = false }
                    else { path.addLine(to: point) }
                    x += step
                }
                let colors = Self.gradientColors.map { $0.opacity(0.7 + Double(layerIndex) * 0.15) }
                canvas.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: colors),
                        startPoint: CGPoint(x: 0, y: size.height / 2),
                        endPoint: CGPoint(x: size.width, y: size.height / 2)
                    ),
                    style: StrokeStyle(lineWidth: 2.2 - Double(layerIndex) * 0.4, lineCap: .round)
                )
            }
        }
    }
}

/// "精準頻譜" (Precision Waveform): seven bars with a per-bar staggered
/// bounce, green/purple jewel tones, height also driven by real voice level.
private struct PrecisionWaveform: View {
    let levels: [Double]

    private static let colors: [Color] = [
        Color(red: 0.447, green: 0.878, blue: 0.643), Color(red: 0.447, green: 0.878, blue: 0.643), Color(red: 0.447, green: 0.878, blue: 0.643),
        Color(red: 0.659, green: 0.510, blue: 0.878), Color(red: 0.659, green: 0.510, blue: 0.878),
        Color(red: 0.447, green: 0.878, blue: 0.643), Color(red: 0.447, green: 0.878, blue: 0.643),
    ]
    private static let baseHeights: [Double] = [0.2, 0.5, 0.8, 1.0, 0.8, 0.5, 0.2]
    private static let phaseOffsets: [Double] = [-0.4, -0.2, 0, -0.3, -0.1, -0.5, -0.2]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = nexVoiceHUDTime(context.date)
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

/// Siri's own indicator is never static, even in silence -- it keeps a slow
/// idle breathing/rotation going and only grows more energetic with voice.
/// The previous version was driven purely by audio level, so during a quiet
/// moment (or before the meter had a sample) it visibly froze.
private struct SiriOrb: View {
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
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
            let t = nexVoiceHUDTime(context.date)
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

/// "浮聲" (Float Voice) -- ultra-thin borderless float: a soft white glow, a
/// bright main wave with a fainter blue secondary wave riding under it, and
/// three small pulsing dots along the left edge.
private struct FloatVoice: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let synthFloor = 0.05 + 0.05 * abs(sin(t * 0.8))
            let energy = max(voiceLevel, synthFloor)

            Canvas { canvas, size in
                canvas.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(colors: [.white.opacity(0.06 + energy * 0.07), .white.opacity(0)]),
                        center: CGPoint(x: size.width / 2, y: size.height / 2),
                        startRadius: 0,
                        endRadius: size.width * 0.5
                    )
                )

                canvas.stroke(
                    nexVoiceSmoothWavePath(size: size, t: t, energy: energy, amplitude: size.height * 0.4, frequency: 3.2, phase: 0.6),
                    with: .color(.white.opacity(0.96)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    nexVoiceSmoothWavePath(size: size, t: t + 0.12, energy: energy * 0.82, amplitude: size.height * 0.33, frequency: 4.6, phase: 2.1),
                    with: .color(Color(red: 0.62, green: 0.78, blue: 1.0).opacity(0.5)),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                )

                for i in 0..<3 {
                    let x = size.width * (0.12 + Double(i) * 0.032)
                    let pulse = 0.55 + 0.45 * sin(t * 2.3 + Double(i))
                    let r: CGFloat = 1.3 + 0.7 * pulse
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: size.height / 2 - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(0.7 + 0.2 * pulse))
                    )
                }
            }
        }
    }
}

/// "虹核" (Prism Core) -- rainbow-tinted glow blobs orbiting additively
/// around a bright core orb, with a soft arc highlight and drifting outer
/// rings.
private struct PrismCore: View {
    let levels: [Double]

    private static let blobColors: [Color] = [
        Color(red: 0.28, green: 0.82, blue: 1.0),
        Color(red: 0.40, green: 0.46, blue: 1.0),
        Color(red: 0.75, green: 0.33, blue: 1.0),
        Color(red: 1.0, green: 0.30, blue: 0.67),
    ]
    private static let ringColors: [Color] = [
        Color(red: 0.56, green: 0.85, blue: 1.0),
        Color(red: 0.75, green: 0.57, blue: 1.0),
        Color(red: 1.0, green: 0.57, blue: 0.80),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let energy = levels.last ?? 0
            let size: CGFloat = 20
            let baseRadius = size * (0.42 + energy * 0.09 + 0.03 * sin(t * 2))

            ZStack {
                ForEach(Self.blobColors.indices, id: \.self) { i in
                    let angle = t * (0.7 + Double(i) * 0.13) + Double(i) * 1.2
                    let ox = cos(angle) * baseRadius * 0.34
                    let oy = sin(angle * 1.1) * baseRadius * 0.31
                    let radius = baseRadius * (1.0 - Double(i) * 0.08)
                    Circle()
                        .fill(RadialGradient(colors: [Self.blobColors[i].opacity(0.8), .clear], center: .center, startRadius: 0, endRadius: radius))
                        .frame(width: radius * 2, height: radius * 2)
                        .offset(x: ox, y: oy)
                        .blendMode(.screen)
                }

                Circle()
                    .fill(RadialGradient(
                        colors: [.white, Color(red: 0.66, green: 0.89, blue: 1.0), Color(red: 0.42, green: 0.40, blue: 1.0), Color(red: 0.94, green: 0.29, blue: 0.75).opacity(0.7), .clear],
                        center: UnitPoint(x: 0.36, y: 0.32),
                        startRadius: 0,
                        endRadius: baseRadius
                    ))
                    .frame(width: baseRadius * 2, height: baseRadius * 2)

                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(.white.opacity(0.44 + energy * 0.28), lineWidth: 1)
                    .frame(width: baseRadius * 1.36, height: baseRadius * 1.36)
                    .rotationEffect(.degrees(-20))

                ForEach(Self.ringColors.indices, id: \.self) { ring in
                    let r = baseRadius * (1.15 + Double(ring + 1) * 0.17 + 0.025 * sin(t * 2 + Double(ring + 1)))
                    Circle()
                        .stroke(Self.ringColors[ring], lineWidth: 0.8)
                        .frame(width: r * 2, height: r * 2)
                        .opacity(0.22)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

/// "赤霞" (Ember) -- three drifting warm glow pools blended additively, a
/// thick amber wave with a thinner rose wave riding underneath, and a
/// handful of rising spark particles.
private struct Ember: View {
    let levels: [Double]

    private static let glowPoints: [(x: Double, y: Double, color: Color, radius: Double)] = [
        (0.30, 0.53, Color(red: 1.0, green: 0.28, blue: 0.18).opacity(0.36), 0.30),
        (0.53, 0.43, Color(red: 1.0, green: 0.54, blue: 0.22).opacity(0.30), 0.36),
        (0.72, 0.57, Color(red: 1.0, green: 0.22, blue: 0.47).opacity(0.24), 0.28),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let synthFloor = 0.05 + 0.05 * abs(sin(t * 0.8))
            let energy = max(voiceLevel, synthFloor)

            Canvas { canvas, size in
                canvas.blendMode = .screen
                for (index, point) in Self.glowPoints.enumerated() {
                    let x = size.width * CGFloat(point.x + sin(t * 0.62 + Double(index)) * 0.035)
                    let y = size.height * CGFloat(point.y + cos(t * 0.73 + Double(index)) * 0.06)
                    let r = size.width * CGFloat(point.radius) * CGFloat(0.78 + energy * 0.22)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(Gradient(colors: [point.color, .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r)
                    )
                }
                canvas.blendMode = .normal

                canvas.stroke(
                    nexVoiceSmoothWavePath(size: size, t: t, energy: energy, amplitude: size.height * 0.4, frequency: 3.1, phase: 1.1),
                    with: .color(Color(red: 1.0, green: 0.69, blue: 0.36).opacity(0.92)),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    nexVoiceSmoothWavePath(size: size, t: t + 0.1, energy: energy * 0.78, amplitude: size.height * 0.32, frequency: 5.2, phase: 2.8),
                    with: .color(Color(red: 1.0, green: 0.31, blue: 0.47).opacity(0.62)),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                )

                for i in 0..<8 {
                    let progress = (t * (0.13 + nexVoiceSeeded(Double(i)) * 0.13) + nexVoiceSeeded(Double(i) * 4.7)).truncatingRemainder(dividingBy: 1)
                    let x = size.width * CGFloat(0.25 + nexVoiceSeeded(Double(i) * 7.4) * 0.5)
                    let y = size.height * CGFloat(0.82 - progress * 0.64)
                    let sparkSize = CGFloat(1.0 + nexVoiceSeeded(Double(i) * 2.8) * 1.2)
                    let color: Color = i % 2 == 0 ? Color(red: 1.0, green: 0.71, blue: 0.36) : Color(red: 1.0, green: 0.36, blue: 0.33)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - sparkSize, y: y - sparkSize, width: sparkSize * 2, height: sparkSize * 2)),
                        with: .color(color.opacity((1 - progress) * (0.25 + energy * 0.5)))
                    )
                }
            }
        }
    }
}

/// Shared idle/listening energy floor for the three HUD Lab ports below
/// (彗尾/雙螺旋/水銀) -- mirrors GlassBars' `0.45 + level*0.55` pattern so
/// silence never reads as a dead/frozen indicator: a slow breathing term
/// keeps power at 0.40+ even at level 0, rising toward 1.0 with real voice.
/// Global animation clock for every HUD visualization. Real time is scaled
/// down so motion reads as calm breathing rather than frantic jitter; energy
/// (not speed) is what voice level modulates.
private func nexVoiceHUDTime(_ date: Date) -> Double {
    date.timeIntervalSinceReferenceDate * 0.55
}

private func nexVoiceHUDLabPower(t: Double, level: Double) -> (power: Double, bloom: Double) {
    let breathe = 0.5 + 0.5 * sin(t * 0.9)
    let power = 0.16 + min(1, max(0, level)) * 0.80 + breathe * 0.04
    return (power, 0.92 + power * 0.18)
}

/// "彗尾" (Comet Trail) -- ported from the NexVoice HUD Lab mockup's 彗尾
/// variant: a two-term sine track (main sway + slower counter-drift) with a
/// bright head that cruises along it dragging a short fading dot trail, on
/// top of a soft halo + gradient stroke of the track itself. Trail length
/// reduced from 9 to 6 dots (perf) with larger radius/alpha to keep the
/// density feel; head/track glow simulated via a wide low-opacity halo
/// stroke underneath the bright core stroke, matching this file's existing
/// Canvas-glow convention (see InkStroke/WaterWave) rather than GraphicsContext filters.
private struct CometTrail: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cy = h / 2
                let amp = h * (0.09 + power * 0.22)
                let rate = 0.85 + power * 0.35

                func yAt(_ x: Double) -> Double {
                    cy + sin(x * 0.145 + t * 2.45 * rate) * amp
                        + sin(x * 0.052 - t * 1.2 * rate) * amp * 0.26
                }

                var trackPoints: [CGPoint] = []
                var x = 0.0
                while x <= w {
                    trackPoints.append(CGPoint(x: x, y: yAt(x)))
                    x += 1
                }
                var track = Path()
                track.addLines(trackPoints)

                canvas.stroke(
                    track,
                    with: .color(Color(red: 0.41, green: 0.89, blue: 1.0).opacity(0.22)),
                    style: StrokeStyle(lineWidth: 5.2 * bloom, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    track,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.31, green: 0.47, blue: 1.0).opacity(0.55),
                            Color(red: 0.30, green: 0.87, blue: 1.0).opacity(0.92),
                            Color(red: 0.87, green: 1.0, blue: 1.0).opacity(0.98),
                            Color(red: 0.36, green: 0.47, blue: 1.0).opacity(0.58),
                        ]),
                        startPoint: CGPoint(x: 0, y: cy),
                        endPoint: CGPoint(x: w, y: cy)
                    ),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )

                let phase = (t * 23 * rate).truncatingRemainder(dividingBy: w)
                let hx = phase
                let hy = yAt(hx)

                for i in stride(from: 6, through: 1, by: -1) {
                    let tx = max(0, hx - Double(i) * 3.4)
                    let ty = yAt(tx)
                    let a = pow(1 - Double(i) / 7, 1.6)
                    let r = max(0.9, 3.4 - Double(i) * 0.3)
                    let dotColor = i < 3
                        ? Color(red: 0.84, green: 1.0, blue: 1.0)
                        : Color(red: 0.29, green: 0.78, blue: 1.0)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: tx - r, y: ty - r, width: r * 2, height: r * 2)),
                        with: .color(dotColor.opacity(a * 0.75))
                    )
                }

                let core = 3.0 + power * 1.4
                canvas.fill(
                    Path(ellipseIn: CGRect(x: hx - core, y: hy - core, width: core * 2, height: core * 2)),
                    with: .radialGradient(
                        Gradient(colors: [
                            .white,
                            Color(red: 0.87, green: 1.0, blue: 1.0),
                            Color(red: 0.49, green: 0.94, blue: 1.0),
                            Color(red: 0.29, green: 0.78, blue: 1.0).opacity(0),
                        ]),
                        center: CGPoint(x: hx - 0.6, y: hy - 0.6),
                        startRadius: 0,
                        endRadius: core
                    )
                )
                canvas.fill(
                    Path(ellipseIn: CGRect(x: hx - core * 0.42, y: hy - core * 0.42, width: core * 0.84, height: core * 0.84)),
                    with: .color(.white.opacity(0.96))
                )
            }
        }
    }
}

/// "雙螺旋" (Helix) -- ported from the NexVoice HUD Lab mockup's 雙螺旋
/// variant: two counter-phased sine bands (violet drawn first/behind, cyan
/// drawn second/in-front so it reads as nearer), bright pip nodes at each
/// crossing, and a small sweeping highlight dot riding between the two
/// strands. Each band gets the same halo+gradient double-stroke treatment
/// as CometTrail.
private struct Helix: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cy = h / 2
                let amp = h * (0.16 + power * 0.19)
                let rate = 0.85 + power * 0.35
                let phase = t * 2.05 * rate

                func y1(_ x: Double) -> Double { cy + sin(x * 0.185 + phase) * amp }
                func y2(_ x: Double) -> Double { cy + sin(x * 0.185 + phase + .pi) * amp }

                func pathFor(_ fn: (Double) -> Double) -> Path {
                    var points: [CGPoint] = []
                    var x = 0.0
                    while x <= w {
                        points.append(CGPoint(x: x, y: fn(x)))
                        x += 1
                    }
                    var path = Path()
                    path.addLines(points)
                    return path
                }

                let backBand = pathFor(y2)
                canvas.stroke(
                    backBand,
                    with: .color(Color(red: 0.62, green: 0.42, blue: 1.0).opacity(0.20)),
                    style: StrokeStyle(lineWidth: 4.8 * bloom, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    backBand,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.40, green: 0.42, blue: 1.0).opacity(0.5),
                            Color(red: 0.65, green: 0.55, blue: 1.0).opacity(0.62),
                            Color(red: 1.0, green: 0.51, blue: 0.81).opacity(0.88),
                            Color(red: 0.48, green: 0.38, blue: 1.0).opacity(0.52),
                        ]),
                        startPoint: CGPoint(x: 0, y: cy),
                        endPoint: CGPoint(x: w, y: cy)
                    ),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )

                let frontBand = pathFor(y1)
                canvas.stroke(
                    frontBand,
                    with: .color(Color(red: 0.28, green: 0.89, blue: 1.0).opacity(0.22)),
                    style: StrokeStyle(lineWidth: 5.0 * bloom, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    frontBand,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.29, green: 0.59, blue: 1.0).opacity(0.62),
                            Color(red: 0.52, green: 0.96, blue: 1.0).opacity(0.96),
                            Color(red: 0.95, green: 1.0, blue: 1.0).opacity(0.98),
                            Color(red: 0.31, green: 0.62, blue: 1.0).opacity(0.62),
                        ]),
                        startPoint: CGPoint(x: 0, y: cy),
                        endPoint: CGPoint(x: w, y: cy)
                    ),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )

                let nodeSpacing = max(8.0, w / 5.5)
                var nx = 4.0
                while nx < w {
                    let crossing = sin(nx * 0.185 + phase)
                    let near = abs(crossing)
                    if near < 0.34 {
                        let pulse = 1 - near / 0.34
                        let r = 1.1 + pulse * (1.0 + power * 0.7)
                        canvas.fill(
                            Path(ellipseIn: CGRect(x: nx - r, y: cy - r, width: r * 2, height: r * 2)),
                            with: .color(Color(red: 0.96, green: 1.0, blue: 1.0).opacity(0.62 + pulse * 0.38))
                        )
                    }
                    nx += nodeSpacing
                }

                let sweep = (sin(t * 2.6 * rate) + 1) / 2
                let sx = sweep * w
                let sy = (y1(sx) + y2(sx)) / 2
                let sr = 1.3 + power
                canvas.fill(
                    Path(ellipseIn: CGRect(x: sx - sr, y: sy - sr, width: sr * 2, height: sr * 2)),
                    with: .color(.white.opacity(0.95))
                )
            }
        }
    }
}

/// "水銀" (Mercury) -- ported from the NexVoice HUD Lab mockup's 水銀
/// variant: a filled liquid-metal ribbon body (independent rippling top/
/// bottom edges) with a white->cyan->blue-grey vertical gradient fill, a
/// bright top-edge stroke, a screen-blended mirror-sheen band sweeping
/// across the body, and a small orbiting highlight bead riding inside.
private struct Mercury: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cy = h / 2
                let rate = 0.85 + power * 0.35
                let half = h * (0.17 + power * 0.15)
                let ripple = h * (0.05 + power * 0.045)

                func top(_ x: Double) -> Double {
                    cy - half - sin(x * 0.135 + t * 1.85 * rate) * ripple
                        - sin(x * 0.046 - t * 0.9 * rate) * (ripple * 0.5)
                }
                func bottom(_ x: Double) -> Double {
                    cy + half + sin(x * 0.129 + t * 1.62 * rate + 1.15) * ripple * 0.82
                        + sin(x * 0.052 + t * 0.74 * rate) * (ripple * 0.4)
                }

                var ribbon = Path()
                ribbon.move(to: CGPoint(x: 0, y: top(0)))
                var x = 1.0
                while x <= w { ribbon.addLine(to: CGPoint(x: x, y: top(x))); x += 1 }
                x = w
                while x >= 0 { ribbon.addLine(to: CGPoint(x: x, y: bottom(x))); x -= 1 }
                ribbon.closeSubpath()

                canvas.fill(
                    ribbon,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0.98), location: 0),
                            .init(color: Color(red: 0.79, green: 0.97, blue: 1.0).opacity(0.93), location: 0.18),
                            .init(color: Color(red: 0.34, green: 0.59, blue: 0.70).opacity(0.76), location: 0.48),
                            .init(color: Color(red: 0.78, green: 0.89, blue: 0.93).opacity(0.9), location: 0.7),
                            .init(color: Color(red: 0.35, green: 0.41, blue: 0.69).opacity(0.72), location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: cy - half - ripple),
                        endPoint: CGPoint(x: 0, y: cy + half + ripple)
                    )
                )

                var topEdge = Path()
                topEdge.move(to: CGPoint(x: 0, y: top(0)))
                x = 1.0
                while x <= w { topEdge.addLine(to: CGPoint(x: x, y: top(x))); x += 1 }
                canvas.stroke(
                    topEdge,
                    with: .color(.white.opacity(0.30)),
                    style: StrokeStyle(lineWidth: 3.2 * bloom, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    topEdge,
                    with: .color(.white.opacity(0.96)),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                )

                let sweepX = (t * 26 * rate).truncatingRemainder(dividingBy: w + 24) - 12
                canvas.blendMode = .screen
                canvas.fill(
                    ribbon,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0), location: 0),
                            .init(color: .white.opacity(0.12), location: 0.36),
                            .init(color: .white.opacity(0.9), location: 0.5),
                            .init(color: Color(red: 0.71, green: 0.97, blue: 1.0).opacity(0.2), location: 0.64),
                            .init(color: .white.opacity(0), location: 1),
                        ]),
                        startPoint: CGPoint(x: sweepX - 10, y: 0),
                        endPoint: CGPoint(x: sweepX + 10, y: 0)
                    )
                )
                canvas.blendMode = .normal

                let orbX = w * (0.5 + 0.43 * sin(t * 0.82 * rate))
                let orbY = cy + sin(t * 1.7 * rate) * (h * 0.05)
                let orbR = h * (0.16 + power * 0.05)
                canvas.fill(
                    Path(ellipseIn: CGRect(x: orbX - orbR, y: orbY - orbR, width: orbR * 2, height: orbR * 2)),
                    with: .radialGradient(
                        Gradient(colors: [
                            .white.opacity(0.92),
                            Color(red: 0.81, green: 0.97, blue: 1.0).opacity(0.4),
                            Color(red: 0.35, green: 0.51, blue: 1.0).opacity(0),
                        ]),
                        center: CGPoint(x: orbX - 0.6, y: orbY - 0.6),
                        startRadius: 0,
                        endRadius: orbR
                    )
                )
            }
        }
    }
}

/// "心電" (EKG) -- ported from the NexVoice HUD Lab mockup's 心電 variant: a
/// faint breathing baseline sine with a bright Gaussian-enveloped pulse
/// packet that scans left-to-right, a fading trailing streak behind the
/// pulse head, and a bright bloom dot riding at the head -- mirrors the
/// halo+gradient double-stroke bloom convention used by CometTrail/Helix/Mercury.
private struct EKG: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cy = h / 2
                let amp = 4.5 + power * 6.0
                let rate = 0.85 + power * 0.35
                let scanX = (t * 24 * rate).truncatingRemainder(dividingBy: w)
                let trail = 9 + power * 4

                func baseline(_ x: Double) -> Double {
                    cy + sin(x * 0.16 + t * 1.4 * rate) * 1.2
                }
                func packet(_ x: Double, _ center: Double) -> Double {
                    let d = x - center
                    let envelope = exp(-(d * d) / (26 + power * 30))
                    return envelope * (
                        sin(d * 0.9) * amp * 0.32 +
                        sin(d * 1.7) * amp * 0.58 +
                        sin(d * 0.34) * amp * 0.2
                    )
                }
                func waveform(_ x: Double) -> Double {
                    // Two relay pulse packets so the trace never reads as an
                    // empty flat line between beats.
                    let second = (scanX + w / 2).truncatingRemainder(dividingBy: w)
                    return baseline(x) + packet(x, scanX) + packet(x, second) * 0.7
                }

                var basePoints: [CGPoint] = []
                var x = 0.0
                while x <= w { basePoints.append(CGPoint(x: x, y: baseline(x))); x += 1 }
                var basePath = Path()
                basePath.addLines(basePoints)
                canvas.stroke(
                    basePath,
                    with: .color(Color(red: 0.24, green: 0.80, blue: 1.0).opacity(0.30)),
                    style: StrokeStyle(lineWidth: 3.6 * bloom, lineCap: .round, lineJoin: .round)
                )

                var points: [CGPoint] = []
                x = 0.0
                while x <= w { points.append(CGPoint(x: x, y: waveform(x))); x += 0.6 }
                var path = Path()
                path.addLines(points)
                canvas.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.31, green: 0.43, blue: 1.0).opacity(0.5),
                            Color(red: 0.26, green: 0.84, blue: 1.0).opacity(0.94),
                            Color(red: 0.88, green: 1.0, blue: 1.0).opacity(0.98),
                            Color(red: 0.50, green: 0.43, blue: 1.0).opacity(0.55),
                        ]),
                        startPoint: CGPoint(x: 0, y: cy),
                        endPoint: CGPoint(x: w, y: cy)
                    ),
                    style: StrokeStyle(lineWidth: 1.3 + power * 0.5, lineCap: .round, lineJoin: .round)
                )

                var trailPoints: [CGPoint] = []
                var tx = max(0, scanX - trail)
                while tx <= scanX { trailPoints.append(CGPoint(x: tx, y: waveform(tx))); tx += 0.5 }
                var trailPath = Path()
                trailPath.addLines(trailPoints)
                canvas.stroke(
                    trailPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.26, green: 0.84, blue: 1.0).opacity(0),
                            Color(red: 0.90, green: 1.0, blue: 1.0).opacity(0.9),
                        ]),
                        startPoint: CGPoint(x: scanX - trail, y: cy),
                        endPoint: CGPoint(x: scanX, y: cy)
                    ),
                    style: StrokeStyle(lineWidth: 1.9 + power * 0.4, lineCap: .round, lineJoin: .round)
                )

                let hy = waveform(scanX)
                let core = 1.6 + power * 0.7
                canvas.fill(
                    Path(ellipseIn: CGRect(x: scanX - core * 2, y: hy - core * 2, width: core * 4, height: core * 4)),
                    with: .radialGradient(
                        Gradient(colors: [
                            .white,
                            Color(red: 0.91, green: 1.0, blue: 1.0),
                            Color(red: 0.42, green: 0.84, blue: 1.0).opacity(0),
                        ]),
                        center: CGPoint(x: scanX - 0.4, y: hy - 0.4),
                        startRadius: 0,
                        endRadius: core * 2
                    )
                )
                canvas.fill(
                    Path(ellipseIn: CGRect(x: scanX - core * 0.5, y: hy - core * 0.5, width: core, height: core)),
                    with: .color(.white.opacity(0.97))
                )
            }
        }
    }
}

/// "流星群" (Meteor Shower) -- ported from the NexVoice HUD Lab mockup's
/// 流星群 variant: a shared undulating track band with three meteors
/// travelling along it in a fixed relay (evenly spaced, deterministic
/// per-meteor phase offsets -- no Double.random), each dragging a short
/// segmented fading tail and a bright bloom head. Segment count reduced
/// from the mockup's 8 to 6 (perf, matches CometTrail's own 9->6 reduction)
/// with larger radius/alpha to keep the density feel.
private struct MeteorShower: View {
    let levels: [Double]
    private static let count = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cy = h / 2
                let amp = h * (0.10 + power * 0.16)
                let rate = 0.85 + power * 0.35

                func trackY(_ x: Double, phase: Double = 0) -> Double {
                    cy + sin(x * 0.20 + t * 1.6 * rate + phase) * amp
                        + sin(x * 0.07 - t * 0.8 * rate) * amp * 0.22
                }

                var bandPoints: [CGPoint] = []
                var x = 0.0
                while x <= w { bandPoints.append(CGPoint(x: x, y: trackY(x))); x += 1 }
                var band = Path()
                band.addLines(bandPoints)

                canvas.stroke(
                    band,
                    with: .color(Color(red: 0.33, green: 0.84, blue: 1.0).opacity(0.18)),
                    style: StrokeStyle(lineWidth: 4.4 * bloom, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    band,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.36, green: 0.40, blue: 1.0).opacity(0.42),
                            Color(red: 0.34, green: 0.90, blue: 1.0).opacity(0.9),
                            Color(red: 0.55, green: 0.47, blue: 1.0).opacity(0.38),
                        ]),
                        startPoint: CGPoint(x: 0, y: cy),
                        endPoint: CGPoint(x: w, y: cy)
                    ),
                    style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
                )

                for i in 0..<Self.count {
                    let spacing = w / Double(Self.count)
                    let progress = (t * (15 + power * 20) * rate + Double(i) * spacing)
                        .truncatingRemainder(dividingBy: w)
                    let hx = progress
                    let hy = trackY(hx, phase: Double(i) * 0.12)
                    let tailLength = 9.0 + power * 6
                    let segments = 6

                    for j in stride(from: segments, through: 1, by: -1) {
                        let d = Double(j) * (tailLength / Double(segments))
                        let tx = max(0, min(w, hx - d))
                        let ty = trackY(tx, phase: Double(i) * 0.12)
                        let a = pow(1 - Double(j) / Double(segments + 1), 1.8)
                        let r = 0.45 + Double(segments - j) * 0.1
                        let color = i % 2 == 0
                            ? Color(red: 0.38, green: 0.89, blue: 1.0)
                            : Color(red: 0.55, green: 0.47, blue: 1.0)
                        canvas.fill(
                            Path(ellipseIn: CGRect(x: tx - r, y: ty - r, width: r * 2, height: r * 2)),
                            with: .color(color.opacity(a * 0.78))
                        )
                    }

                    let radius = 1.3 + power * 0.7
                    let headColor = i % 2 == 0
                        ? Color(red: 0.47, green: 0.93, blue: 1.0)
                        : Color(red: 0.66, green: 0.58, blue: 1.0)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: hx - radius * 2, y: hy - radius * 2, width: radius * 4, height: radius * 4)),
                        with: .radialGradient(
                            Gradient(colors: [.white, Color(red: 0.93, green: 1.0, blue: 1.0), headColor.opacity(0)]),
                            center: CGPoint(x: hx - 0.4, y: hy - 0.4),
                            startRadius: 0,
                            endRadius: radius * 2
                        )
                    )
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: hx - radius * 0.5, y: hy - radius * 0.5, width: radius, height: radius)),
                        with: .color(.white.opacity(0.95))
                    )
                }
            }
        }
    }
}

/// "電漿" (Plasma) -- ported from the NexVoice HUD Lab mockup's 電漿
/// variant: a dual-harmonic arcing wave (envelope-tapered to flat at both
/// ends) with a fainter secondary counter-phased arc riding underneath, a
/// bright bloom node at each end, and a small node marker sweeping back and
/// forth along the arc.
private struct Plasma: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cy = h / 2
                let amp = h * (0.11 + power * 0.20)
                let rate = 0.85 + power * 0.35
                let phase = t * 2.5 * rate
                let thickness = 1.1 + power * 1.3

                func arcY(_ x: Double, offset: Double = 0, flip: Double = 1) -> Double {
                    let n = x / w
                    let envelope = sin(n * .pi)
                    return cy
                        + sin(x * 0.29 + phase + offset) * amp * envelope * flip
                        + sin(x * 0.60 - phase * 1.2 + offset) * amp * 0.3 * envelope
                }

                var hazePoints: [CGPoint] = []
                var x = 0.0
                while x <= w { hazePoints.append(CGPoint(x: x, y: arcY(x))); x += 0.7 }
                var haze = Path()
                haze.addLines(hazePoints)
                canvas.stroke(
                    haze,
                    with: .color(Color(red: 0.34, green: 0.81, blue: 1.0).opacity(0.16)),
                    style: StrokeStyle(lineWidth: (5.2 + power * 1.4) * bloom, lineCap: .round, lineJoin: .round)
                )

                var outerPoints: [CGPoint] = []
                x = 0.0
                while x <= w { outerPoints.append(CGPoint(x: x, y: arcY(x, offset: 0.23, flip: 0.82))); x += 0.55 }
                var outer = Path()
                outer.addLines(outerPoints)
                canvas.stroke(
                    outer,
                    with: .color(Color(red: 0.62, green: 0.45, blue: 1.0).opacity(0.4)),
                    style: StrokeStyle(lineWidth: 0.8 + power * 0.6, lineCap: .round, lineJoin: .round)
                )

                var corePoints: [CGPoint] = []
                x = 0.0
                while x <= w { corePoints.append(CGPoint(x: x, y: arcY(x))); x += 0.5 }
                var core = Path()
                core.addLines(corePoints)
                canvas.stroke(
                    core,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.66, green: 0.98, blue: 1.0).opacity(0.95),
                            Color(red: 0.34, green: 0.81, blue: 1.0).opacity(0.96),
                            Color(red: 1.0, green: 1.0, blue: 1.0).opacity(1),
                            Color(red: 0.56, green: 0.49, blue: 1.0).opacity(0.98),
                            Color(red: 0.79, green: 0.98, blue: 1.0).opacity(0.95),
                        ]),
                        startPoint: CGPoint(x: 0, y: cy),
                        endPoint: CGPoint(x: w, y: cy)
                    ),
                    style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round)
                )

                let pulse = 0.78 + 0.22 * sin(t * 4.4 * rate)
                let endpoints: [(x: Double, color: Color)] = [
                    (0, Color(red: 0.66, green: 0.98, blue: 1.0)),
                    (w, Color(red: 0.71, green: 0.60, blue: 1.0)),
                ]
                canvas.opacity = pulse
                for endpoint in endpoints {
                    let py = arcY(endpoint.x)
                    let radius = 1.5 + power * 0.9
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: endpoint.x - radius * 2.4, y: py - radius * 2.4, width: radius * 4.8, height: radius * 4.8)),
                        with: .radialGradient(
                            Gradient(colors: [.white, endpoint.color, endpoint.color.opacity(0)]),
                            center: CGPoint(x: endpoint.x, y: py - 0.4),
                            startRadius: 0,
                            endRadius: radius * 2.4
                        )
                    )
                }
                canvas.opacity = 1

                let nodeX = w * (0.5 + 0.42 * sin(t * 1.8 * rate))
                let nodeY = arcY(nodeX)
                let nodeRadius = 0.9 + power * 0.5
                canvas.fill(
                    Path(ellipseIn: CGRect(x: nodeX - nodeRadius, y: nodeY - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2)),
                    with: .color(.white)
                )
            }
        }
    }
}

/// "絲綢" (Silk) -- ported from the NexVoice HUD Lab p3 mockup's 絲綢
/// variant: two flowing ribbon strands (cream main + warm-gold secondary),
/// each an amplitude-modulated sine riding a slower cosine envelope,
/// through the halo+gradient double-stroke bloom convention shared with
/// CometTrail/Helix/Mercury. The envelope spans the middle ~84% of the
/// width (not tapered fully to the edges) so idle silence still reads as a
/// wide, present ribbon rather than a pinched flat line.
private struct Silk: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cy = h / 2
                let start = w * 0.08
                let span = w * 0.84
                let amp = h * (0.16 + power * 0.30)
                let rate = 0.85 + power * 0.35

                func strand(offset: Double) -> Path {
                    var points: [CGPoint] = []
                    var x = 0.0
                    while x <= w {
                        let p = min(1, max(0, (x - start) / span))
                        let envelope = sin(p * .pi)
                        let kx = x * 0.11
                        let y = cy + sin(kx + t * 2.1 * rate + offset) * amp * envelope
                            * cos(t * 1.3 * rate + x * 0.025)
                        points.append(CGPoint(x: x, y: y))
                        x += 1
                    }
                    var path = Path()
                    path.addLines(points)
                    return path
                }

                let main = strand(offset: 0)
                canvas.stroke(
                    main,
                    with: .color(Color(red: 0.97, green: 0.83, blue: 0.62).opacity(0.30)),
                    style: StrokeStyle(lineWidth: 5.4 * bloom, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    main,
                    with: .color(Color(red: 1.0, green: 0.90, blue: 0.80).opacity(0.96)),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                )

                let secondary = strand(offset: 1.5)
                canvas.stroke(
                    secondary,
                    with: .color(Color(red: 0.82, green: 0.65, blue: 0.49).opacity(0.20)),
                    style: StrokeStyle(lineWidth: 3.6 * bloom, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    secondary,
                    with: .color(Color(red: 0.89, green: 0.72, blue: 0.55).opacity(0.88)),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}

/// "光瀑" (Cascade) -- ported from the NexVoice HUD Lab p3 mockup's 光瀑
/// variant: a cyan/white light stream of particles advancing left-to-right
/// in a fixed relay (deterministic per-particle size via nexVoiceSeeded, no
/// Double.random) riding a glowing guide track that carries the
/// halo+gradient bloom look shared with CometTrail/MeteorShower. Particle
/// count reduced from the mockup's 12 to 9 (perf, matches CometTrail's own
/// 9->6 reduction) with larger radius/alpha to keep the density feel.
private struct Cascade: View {
    let levels: [Double]
    private static let count = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cy = h / 2
                let rate = 0.85 + power * 0.35
                let heightAmp = h * (0.20 + power * 0.32)

                func trackY(_ x: Double) -> Double {
                    let n = min(1, max(0, x / w))
                    let envelope = sin(n * .pi)
                    return cy + sin(x * 0.12 + t * 2.6 * rate) * heightAmp * envelope
                }

                var trackPoints: [CGPoint] = []
                var x = 0.0
                while x <= w { trackPoints.append(CGPoint(x: x, y: trackY(x))); x += 1 }
                var track = Path()
                track.addLines(trackPoints)

                canvas.stroke(
                    track,
                    with: .color(Color(red: 0.29, green: 0.69, blue: 0.85).opacity(0.22)),
                    style: StrokeStyle(lineWidth: 4.8 * bloom, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    track,
                    with: .color(Color(red: 0.55, green: 0.91, blue: 1.0).opacity(0.90)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )

                let speed = w * (0.55 + power * 0.95)
                let spacing = w * 1.15 / Double(Self.count)
                for i in 0..<Self.count {
                    let xPos = (Double(i) * spacing + t * speed)
                        .truncatingRemainder(dividingBy: w + spacing) - spacing * 0.5
                    guard xPos > -3 && xPos < w + 3 else { continue }
                    let clampedX = max(0, min(w, xPos))
                    let yPos = trackY(clampedX) + sin(xPos * 0.22 + t * 3.4 * rate + Double(i)) * heightAmp * 0.22
                    let r: CGFloat = 1.5 + CGFloat(nexVoiceSeeded(Double(i) * 5.6)) * 0.9
                    let color = i % 2 == 0
                        ? Color(red: 0.55, green: 0.91, blue: 1.0)
                        : Color.white
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: xPos - r, y: yPos - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(colors: [.white, color, color.opacity(0)]),
                            center: CGPoint(x: xPos, y: yPos),
                            startRadius: 0,
                            endRadius: r
                        )
                    )
                }
            }
        }
    }
}

/// "日蝕" (Eclipse) -- reworked from the NexVoice HUD Lab p3 mockup's 日蝕
/// variant for the 78x26 horizontal capsule: the mockup's centered circular
/// corona is stretched into a wide horizontal composition (elliptical
/// corona rings + two outward-sweeping prominence streaks reaching toward
/// each end of the capsule) so idle silence reads as a wide presence across
/// the frame instead of one small dot pinched in the middle -- the failure
/// mode that got the retired "量子" variant sent back. The dark core stays
/// centered, ringed by a bright eclipse-ring stroke (the halo+gradient
/// bloom convention shared with CometTrail/Helix/Mercury).
private struct Eclipse: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = nexVoiceHUDTime(context.date)
            let voiceLevel = levels.last ?? 0
            let (power, bloom) = nexVoiceHUDLabPower(t: t, level: voiceLevel)

            Canvas { canvas, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let cx = w / 2
                let cy = h / 2
                let rate = 0.85 + power * 0.35
                let coreRadius = h * (0.24 + power * 0.16)

                // Elliptical corona rings -- the mockup's circular corona
                // stretched wide so it reads as a horizontal light band
                // instead of a small centered dot.
                for ring in 0..<3 {
                    let rx = coreRadius + w * (0.11 + Double(ring) * 0.115) + power * 2
                    let ry = coreRadius + h * (0.05 + Double(ring) * 0.03)
                    let a = (0.5 - Double(ring) * 0.14) * (0.7 + power * 0.3)
                    canvas.stroke(
                        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)),
                        with: .color(Color(red: 1.0, green: 0.60, blue: 0.35).opacity(a)),
                        style: StrokeStyle(lineWidth: 1.1)
                    )
                }

                // Crescent prominence streaks sweeping out from the core
                // toward each end of the capsule -- ports the mockup's two
                // side flare rects as flowing arcs so they read as
                // continuous light reaching the frame edges, not dots.
                let reach = w * (0.36 + power * 0.10)
                func prominence(direction: Double) -> Path {
                    var points: [CGPoint] = []
                    var i = 0.0
                    while i <= 1 {
                        let x = cx + direction * (coreRadius + 2 + i * reach)
                        let wobble = sin(i * .pi) * sin(t * 2.2 * rate + i * 4 + direction * 1.6) * (1.1 + power * 1.9)
                        points.append(CGPoint(x: x, y: cy + wobble))
                        i += 0.06
                    }
                    var path = Path()
                    path.addLines(points)
                    return path
                }

                for direction in [-1.0, 1.0] {
                    let band = prominence(direction: direction)
                    canvas.stroke(
                        band,
                        with: .color(Color(red: 1.0, green: 0.58, blue: 0.33).opacity(0.22)),
                        style: StrokeStyle(lineWidth: 4.0 * bloom, lineCap: .round, lineJoin: .round)
                    )
                    canvas.stroke(
                        band,
                        with: .color(Color(red: 1.0, green: 0.80, blue: 0.58).opacity(0.90)),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                    )
                }

                // Dark core ringed by the bright eclipse-ring stroke.
                let coreRect = CGRect(x: cx - coreRadius, y: cy - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
                canvas.fill(Path(ellipseIn: coreRect), with: .color(Color(red: 0.043, green: 0.043, blue: 0.055)))
                canvas.stroke(
                    Path(ellipseIn: coreRect),
                    with: .color(Color(red: 1.0, green: 0.42, blue: 0.21).opacity(0.30)),
                    style: StrokeStyle(lineWidth: 3.2 * bloom)
                )
                canvas.stroke(
                    Path(ellipseIn: coreRect),
                    with: .color(Color(red: 1.0, green: 0.71, blue: 0.51).opacity(0.96)),
                    style: StrokeStyle(lineWidth: 1.5)
                )
            }
        }
    }
}
