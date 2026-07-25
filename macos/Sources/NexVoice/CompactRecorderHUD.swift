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
            let t = context.date.timeIntervalSinceReferenceDate
            let level = levels.last ?? 0
            let energy = 0.45 + min(1, level) * 0.55
            HStack(alignment: .center, spacing: 1.3) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    let u = Double(index) / Double(Self.barCount - 1)
                    // Center-weighted, with two side lobes so it's not a plain hill.
                    let envelope = 0.30 + 0.70 * pow(sin(u * .pi), 1.4)
                        + 0.18 * sin(u * .pi * 3.1)
                    let wobble = 0.5 + 0.5 * sin(t * 5.2 + Double(index) * 0.9)
                        * sin(t * 2.3 + Double(index) * 0.35)
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
                    let t = context.date.timeIntervalSinceReferenceDate
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
                    let t = context.date.timeIntervalSinceReferenceDate
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
                let t = context.date.timeIntervalSinceReferenceDate
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
            case .mono:
                MonoLevelMeter(levels: levels)
            case .siri:
                SiriOrb(level: levels.last ?? 0)
            case .quantum:
                QuantumOrb(level: levels.last ?? 0)
            case .ripple:
                MinimalistRipple(level: levels.last ?? 0)
            case .spectrum:
                PrecisionWaveform(levels: levels)
            case .amber:
                AmberResonance(level: levels.last ?? 0)
            case .sketch:
                PencilSketch(level: levels.last ?? 0)
            case .incense:
                ZenIncense(level: levels.last ?? 0)
            case .dots:
                MinimalDots(levels: levels)
            case .floatVoice:
                FloatVoice(levels: levels)
            case .prismCore:
                PrismCore(levels: levels)
            case .pulseField:
                PulseField(levels: levels)
            case .stardust:
                Stardust(levels: levels)
            case .frost:
                Frost(levels: levels)
            case .ember:
                Ember(levels: levels)
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
            let t = context.date.timeIntervalSinceReferenceDate
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
                            with: .color(Color(red: 0.133, green: 0.122, blue: 0.102).opacity(0.92)),
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
                        with: .color(Color(red: 0.133, green: 0.122, blue: 0.102).opacity(0.18)),
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
            auroraCanvas(t: context.date.timeIntervalSinceReferenceDate)
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

/// “羽量” (mono) —— 打字機時代的點陣電平表，窄墨灰條、點陣音量柱。
private struct MonoLevelMeter: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { _ in
            let width: CGFloat = 46
            let height: CGFloat = 24
            let columnWidth: CGFloat = width / 46
            let rowHeight: CGFloat = height / 7
            
            Canvas { canvas, size in
                let hist = Array(levels.dropLast().prefix(46)) // Keep last 46 elements
                
                for (colIndex, level) in hist.enumerated() {
                    let colX = CGFloat(colIndex) * columnWidth
                    
                    for rowIndex in 0..<7 {
                        let rowY = CGFloat(rowIndex) * rowHeight
                        let fromMid = abs(Double(rowIndex) - 3.0)
                        let on = fromMid < level * 7 // Normalize level to rows
                        
                        canvas.fill(
                            Path { path in
                                path.move(to: CGPoint(x: colX + columnWidth/2, y: rowY + rowHeight/2))
                                path.addEllipse(in: CGRect(
                                    x: colX,
                                    y: rowY,
                                    width: columnWidth,
                                    height: rowHeight
                                ))
                            },
                            with: .color(on ? Color(red: 0.973, green: 0.918, blue: 0.816) : Color(red: 0.858, green: 0.871, blue: 0.882).opacity(0.1))
                        )
                    }
                }
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
                        colors: [Color(red: 0.659, green: 0.510, blue: 0.878).opacity(0.6), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.5
                    ))
                    .blur(radius: 3)
                    .scaleEffect(0.7 + glow1 * 0.35 * energy)
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 0.447, green: 0.878, blue: 0.643).opacity(0.6), .clear],
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
                        .stroke(Color(red: 0.447, green: 0.878, blue: 0.643), lineWidth: max(0.5, 3 * (1 - localT)))
                        .frame(width: diameter, height: diameter)
                        .opacity(max(0, 1 - localT))
                }
                Circle()
                    .fill(Color(red: 0.447, green: 0.878, blue: 0.643))
                    .frame(width: 5, height: 5)
                    .shadow(color: Color(red: 0.447, green: 0.878, blue: 0.643).opacity(0.5), radius: 2)
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
            let blinkOn = Int(context.date.timeIntervalSinceReferenceDate / 0.4).isMultiple(of: 2)
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

/// Deterministic hash used by the ports below (星塵/霜息/赤霞) -- mirrors the
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
            let t = context.date.timeIntervalSinceReferenceDate
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
            let t = context.date.timeIntervalSinceReferenceDate
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

/// "脈界" (Pulse Field) -- a faint teal measurement grid with a horizontal
/// sweep band scanning across it, a glowing waveform riding on top, and a
/// thin row of jittering bars underneath for texture.
private struct PulseField: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let voiceLevel = levels.last ?? 0
            let synthFloor = 0.05 + 0.05 * abs(sin(t * 0.8))
            let energy = max(voiceLevel, synthFloor)
            let gridColor = Color(red: 0.46, green: 0.87, blue: 0.78)

            Canvas { canvas, size in
                let columns = 9
                let rows = 4
                for c in 0...columns {
                    let x = size.width * CGFloat(c) / CGFloat(columns)
                    canvas.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                  with: .color(gridColor.opacity(0.12)), lineWidth: 0.5)
                }
                for r in 0...rows {
                    let y = size.height * CGFloat(r) / CGFloat(rows)
                    canvas.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                  with: .color(gridColor.opacity(0.12)), lineWidth: 0.5)
                }

                let sweepX = CGFloat((t * 30).truncatingRemainder(dividingBy: Double(size.width) * 1.25) - Double(size.width) * 0.15)
                let bandWidth = size.width * 0.16
                canvas.fill(
                    Path(CGRect(x: sweepX - bandWidth / 2, y: 0, width: bandWidth, height: size.height)),
                    with: .linearGradient(
                        Gradient(colors: [gridColor.opacity(0), gridColor.opacity(0.08 + energy * 0.2), gridColor.opacity(0)]),
                        startPoint: CGPoint(x: sweepX - bandWidth / 2, y: 0),
                        endPoint: CGPoint(x: sweepX + bandWidth / 2, y: 0)
                    )
                )

                canvas.stroke(
                    nexVoiceSmoothWavePath(size: size, t: t, energy: energy, amplitude: size.height * 0.4, frequency: 4.8, phase: 1.2),
                    with: .color(gridColor.opacity(0.92)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )

                for i in 0..<20 {
                    let p = Double(i) / 19
                    let envelope = pow(sin(p * .pi), 0.7)
                    let a = sin(t * 3.3 + Double(i) * 0.78 + 1.9)
                    let b = sin(t * 5.1 - Double(i) * 0.43 + 1.33)
                    let c = sin(t * 1.7 + Double(i) * 1.31)
                    let signal = abs(a * 0.48 + b * 0.34 + c * 0.18)
                    let magnitude = (0.08 + signal * energy * 0.7) * envelope
                    let barHeight = max(1, size.height * 0.32 * CGFloat(magnitude))
                    let x = size.width * CGFloat(0.08 + p * 0.84)
                    canvas.fill(
                        Path(CGRect(x: x - 0.5, y: size.height / 2 - barHeight / 2, width: 1, height: barHeight)),
                        with: .color(gridColor.opacity(0.4))
                    )
                }
            }
        }
    }
}

/// "星塵" (Stardust) -- particles seeded-orbit a soft core glow, colored in
/// a cyan/violet/pink cycle and additively blended, with a faint wave
/// riding through the middle.
private struct Stardust: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let voiceLevel = levels.last ?? 0
            let synthFloor = 0.05 + 0.05 * abs(sin(t * 0.8))
            let energy = max(voiceLevel, synthFloor)
            let spread = 0.35 + energy * 0.65

            Canvas { canvas, size in
                let cx = size.width / 2
                let cy = size.height / 2

                canvas.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(colors: [Color(red: 0.5, green: 0.56, blue: 1.0).opacity(0.10 + energy * 0.12), .clear]),
                        center: CGPoint(x: cx, y: cy),
                        startRadius: 0,
                        endRadius: size.width * 0.4
                    )
                )

                canvas.blendMode = .screen
                for i in 0..<36 {
                    let baseAngle = nexVoiceSeeded(Double(i) * 2.17) * .pi * 2
                    let orbit = nexVoiceSeeded(Double(i) * 7.31 + 2) * Double(size.width) * 0.42
                    let speed = 0.12 + nexVoiceSeeded(Double(i) * 1.91 + 8) * 0.45
                    let angle = baseAngle + t * speed * (i % 2 == 0 ? 1 : -1)
                    let pulse = 0.6 + 0.4 * sin(t * (1.2 + speed) + Double(i))
                    let radius = orbit * spread * (0.65 + 0.35 * pulse)
                    let x = cx + CGFloat(cos(angle) * radius)
                    let y = cy + CGFloat(sin(angle * 1.18) * radius * 0.35)
                    let dotSize = CGFloat(0.7 + nexVoiceSeeded(Double(i) * 4.77) * 1.3 + energy * 0.6)
                    let hue = i % 3
                    let color: Color = hue == 0
                        ? Color(red: 0.48, green: 0.87, blue: 1.0)
                        : hue == 1 ? Color(red: 0.65, green: 0.54, blue: 1.0) : Color(red: 1.0, green: 0.47, blue: 0.84)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - dotSize, y: y - dotSize, width: dotSize * 2, height: dotSize * 2)),
                        with: .color(color.opacity(0.24 + pulse * 0.72))
                    )
                }
                canvas.blendMode = .normal

                canvas.stroke(
                    nexVoiceSmoothWavePath(size: size, t: t, energy: energy * 0.65, amplitude: size.height * 0.24, frequency: 3.4, phase: 2.7),
                    with: .color(Color(red: 0.92, green: 0.94, blue: 1.0).opacity(0.76)),
                    style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}

/// "霜息" (Frost) -- a cool diagonal mist wash, a scattering of tiny rotating
/// ice-crystal spokes, and two icy-blue glowing waves layered on top.
private struct Frost: View {
    let levels: [Double]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let voiceLevel = levels.last ?? 0
            let synthFloor = 0.05 + 0.05 * abs(sin(t * 0.8))
            let energy = max(voiceLevel, synthFloor)

            Canvas { canvas, size in
                canvas.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.87, green: 0.97, blue: 1.0).opacity(0.09),
                            Color(red: 0.45, green: 0.82, blue: 1.0).opacity(0.03),
                            Color(red: 0.71, green: 0.53, blue: 1.0).opacity(0.07),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )

                for i in 0..<8 {
                    let x = CGFloat(nexVoiceSeeded(Double(i) * 8.2)) * size.width
                    let y = CGFloat(nexVoiceSeeded(Double(i) * 4.1 + 3)) * size.height
                    let radius = size.height * CGFloat(0.16 + nexVoiceSeeded(Double(i) * 9.7) * 0.32)
                    let arms = i % 2 == 0 ? 6 : 5
                    let spin = t * 0.5 * (i % 2 == 0 ? 1 : -1)
                    var crystal = Path()
                    for a in 0..<arms {
                        let armAngle = spin + Double(a) / Double(arms) * .pi * 2
                        let dx = CGFloat(cos(armAngle))
                        let dy = CGFloat(sin(armAngle))
                        crystal.move(to: CGPoint(x: x, y: y))
                        crystal.addLine(to: CGPoint(x: x + dx * radius, y: y + dy * radius))
                    }
                    canvas.stroke(crystal, with: .color(Color(red: 0.86, green: 0.97, blue: 1.0).opacity(0.24)), lineWidth: 0.6)
                }

                canvas.stroke(
                    nexVoiceSmoothWavePath(size: size, t: t, energy: energy, amplitude: size.height * 0.42, frequency: 3.5, phase: 0.8),
                    with: .color(Color(red: 0.79, green: 0.95, blue: 1.0).opacity(0.84)),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )
                canvas.stroke(
                    nexVoiceSmoothWavePath(size: size, t: t + 0.13, energy: energy * 0.7, amplitude: size.height * 0.29, frequency: 5.1, phase: 2.8),
                    with: .color(Color(red: 0.57, green: 0.8, blue: 1.0).opacity(0.52)),
                    style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
                )
            }
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
            let t = context.date.timeIntervalSinceReferenceDate
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
