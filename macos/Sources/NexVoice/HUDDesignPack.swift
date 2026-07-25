import SwiftUI

// Ports of the design-lane waveform packs (Agy/Antigravity, 2026-07-25).
//
// Every function here is a faithful translation of a canvas draw function from
// the prototype galleries, which were drawn against the same voice-phase
// contract the app uses: they read `level`, the 11-sample history and an
// externally supplied `phase`, and never touch a clock of their own. Silence
// therefore renders still here for the same reason it does in the prototype.
//
// Geometry constants come from the prototype's 156x52 canvas and are scaled by
// `plate`, so they hold at the 64x22 plated size and at 2x in naked mode. The
// prototypes carry a 1x/2x toggle for exactly this reason -- a design that only
// works large is what produced the previous roster of thin grey lines.

/// Width of the canvas the prototypes were drawn against.
private let hudReferenceWidth: Double = 156

/// Canvas `shadowColor`/`shadowBlur` has no direct GraphicsContext equivalent;
/// a blurred copy underneath reads the same for one extra layer.
private extension GraphicsContext {
    func glowFill(_ path: Path, _ color: Color, radius: Double) {
        guard radius > 0.2 else { return }
        drawLayer { layer in
            layer.addFilter(.blur(radius: radius))
            layer.fill(path, with: .color(color))
        }
    }

    func glowStroke(_ path: Path, _ color: Color, radius: Double, lineWidth: Double) {
        guard radius > 0.2 else { return }
        drawLayer { layer in
            layer.addFilter(.blur(radius: radius))
            layer.stroke(path, with: .color(color),
                         style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The prototypes are written in CSS `hsl()`; SwiftUI's initialiser is HSB.
private func hudHSL(_ hue: Double, _ saturation: Double, _ lightness: Double, _ alpha: Double = 1) -> Color {
    let l = min(1, max(0, lightness))
    let s = min(1, max(0, saturation))
    let brightness = l + s * min(l, 1 - l)
    let sb = brightness <= 0 ? 0 : 2 * (1 - l / brightness)
    let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    return Color(hue: h / 360, saturation: sb, brightness: brightness, opacity: alpha)
}

private func hudRGB(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

private func hudRounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
    var path = Path()
    let radius = min(w, h) / 2
    path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h),
                        cornerSize: CGSize(width: radius, height: radius))
    return path
}

// MARK: - Redesigned nine

/// "極光" -- was a sharp colour zigzag that read as an ECG trace; now a cluster
/// of soft round-capped colour bars with per-bar hue drift.
struct AuroraBars: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let bars = 9

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let spacing = w / Double(Self.bars + 1)
            let barW = max(3 * plate, w * 0.045)
            let centerY = h / 2

            for i in 0..<Self.bars {
                let x = spacing * Double(i + 1)
                let mid = Double(Self.bars - 1) / 2
                let normI = (Double(i) - mid) / mid
                let histIndex = Int((Double(i) / Double(Self.bars - 1)) * Double(levels.count - 1))
                let history = levels[min(levels.count - 1, max(0, histIndex))]
                let wave = sin(hudPhase * 1.5 + Double(i) * 0.6) * 0.25 + 0.75
                let envelope = cos(normI * .pi * 0.45)
                let amp = (0.12 + (level * 0.7 + history * 0.3) * 0.88 * wave) * envelope
                let barH = max(6 * plate, h * 0.75 * amp)

                let hue = 160 + Double(i) * 18 + sin(hudPhase + Double(i)) * 15
                let bar = hudRounded(x - barW / 2, centerY - barH / 2, barW, barH)
                canvas.glowFill(bar, hudHSL(hue, 1, 0.65, 0.55), radius: (4 + level * 4) * plate)
                canvas.fill(bar, with: .linearGradient(
                    Gradient(colors: [hudHSL(hue, 1, 0.75, 0.95),
                                      hudHSL(hue + 30, 0.95, 0.60, 0.85),
                                      hudHSL(hue + 60, 0.90, 0.50, 0.75)]),
                    startPoint: CGPoint(x: x, y: centerY - barH / 2),
                    endPoint: CGPoint(x: x, y: centerY + barH / 2)
                ))
            }
        }
    }
}

/// "光球" -- three concentric layers (halo, pulsing body, offset specular) so
/// the orb has depth instead of reading as one flat blur.
struct DepthOrb: View {
    @Environment(\.hudPhase) private var hudPhase
    let level: Double

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let cx = w / 2, cy = h / 2
            let maxR = min(w, h) * 0.42
            let pulse = sin(hudPhase * 2) * 0.12 + 0.88
            let baseR = maxR * (0.25 + level * 0.75) * pulse

            let haloR = baseR * 1.8
            canvas.fill(
                Path(ellipseIn: CGRect(x: cx - haloR, y: cy - haloR, width: haloR * 2, height: haloR * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: hudRGB(56, 189, 248, 0.35 + level * 0.35), location: 0),
                        .init(color: hudRGB(99, 102, 241, 0.20 + level * 0.20), location: 0.6),
                        .init(color: hudRGB(15, 23, 42, 0), location: 1),
                    ]),
                    center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: haloR
                )
            )

            let bodyR = max(3, baseR)
            let body = Path(ellipseIn: CGRect(x: cx - bodyR, y: cy - bodyR, width: bodyR * 2, height: bodyR * 2))
            canvas.glowFill(body, hudRGB(56, 189, 248, 0.7), radius: (6 + level * 6) * (w / hudReferenceWidth))
            canvas.fill(body, with: .radialGradient(
                Gradient(colors: [hudRGB(125, 211, 252), hudRGB(56, 189, 248), hudRGB(30, 64, 175)]),
                center: CGPoint(x: cx - bodyR * 0.2, y: cy - bodyR * 0.2),
                startRadius: 0, endRadius: bodyR
            ))

            let coreR = max(1, bodyR * 0.3)
            let core = Path(ellipseIn: CGRect(x: cx - bodyR * 0.15 - coreR, y: cy - bodyR * 0.15 - coreR,
                                              width: coreR * 2, height: coreR * 2))
            canvas.glowFill(core, .white.opacity(0.8), radius: 2)
            canvas.fill(core, with: .color(.white))
        }
    }
}

/// "虹核" -- the hard ring is gone. Three coherent iridescent waves converge on
/// a soft core, so the shape reads as one lit object rather than a framed dot.
struct IrisCore: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let cx = w / 2, cy = h / 2

            for k in 0..<3 {
                let hue = (hudPhase * 40 + Double(k) * 120).truncatingRemainder(dividingBy: 360)
                var path = Path()
                var x = 0.0
                while x <= w {
                    let normX = (x - cx) / (w / 2)
                    let envelope = exp(-normX * normX * 2.5)
                    let y = cy + sin(hudPhase * 2 + normX * 4 + Double(k) * 1.5)
                        * (h * 0.32 * level + 2 * plate) * envelope
                    if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    x += 4 * plate
                }
                let stroke = StrokeStyle(lineWidth: 3.5 * plate, lineCap: .round, lineJoin: .round)
                canvas.glowStroke(path, hudHSL(hue, 0.9, 0.6, 0.8), radius: 3 * plate, lineWidth: 3.5 * plate)
                canvas.stroke(path, with: .color(hudHSL(hue, 0.9, 0.65, 0.5 + level * 0.4)), style: stroke)
            }

            let coreR = max(4 * plate, h * 0.22 * (0.3 + level * 0.7))
            canvas.fill(
                Path(ellipseIn: CGRect(x: cx - coreR, y: cy - coreR, width: coreR * 2, height: coreR * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: hudRGB(244, 114, 182, 0.9), location: 0.5),
                        .init(color: hudRGB(192, 132, 252, 0), location: 1),
                    ]),
                    center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: coreR
                )
            )
        }
    }
}

/// "赤霞" -- was an orange smudge with no readable form; now crisp warm bars
/// over a red bloom, so the ember reading survives at HUD size.
struct EmberBars: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let bars = 11

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let spacing = w / Double(Self.bars + 1)
            let barW = max(3.5 * plate, w * 0.04)
            let cy = h / 2

            canvas.fill(
                Path(CGRect(x: 0, y: 0, width: w, height: h)),
                with: .radialGradient(
                    Gradient(colors: [hudRGB(249, 115, 22, 0.25 + level * 0.35), hudRGB(0, 0, 0, 0)]),
                    center: CGPoint(x: w / 2, y: cy), startRadius: 0, endRadius: w * 0.4
                )
            )

            for i in 0..<Self.bars {
                let x = spacing * Double(i + 1)
                let mid = Double(Self.bars - 1) / 2
                let normI = (Double(i) - mid) / mid
                let envelope = cos(normI * .pi * 0.45)
                let wave = sin(hudPhase * 2 + Double(i) * 0.5) * 0.2 + 0.8
                let amp = (0.1 + level * 0.9) * wave * envelope
                let barH = max(5 * plate, h * 0.72 * amp)
                let bar = hudRounded(x - barW / 2, cy - barH / 2, barW, barH)
                canvas.glowFill(bar, hudRGB(249, 115, 22, 0.6), radius: (3 + level * 4) * plate)
                canvas.fill(bar, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: hudRGB(254, 240, 138), location: 0),
                        .init(color: hudRGB(249, 115, 22), location: 0.4),
                        .init(color: hudRGB(220, 38, 38), location: 1),
                    ]),
                    startPoint: CGPoint(x: x, y: cy - barH / 2),
                    endPoint: CGPoint(x: x, y: cy + barH / 2)
                ))
            }
        }
    }
}

/// "彗尾" -- the trail is now a thick tapered stroke of lagged head positions
/// rather than a hairline, so it keeps its body when scaled down.
struct CometStream: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let cx = w / 2, cy = h / 2
            let reach = w * 0.35 * (0.2 + level * 0.8)
            let lift = h * 0.2 * (0.2 + level * 0.8)

            func position(_ p: Double) -> CGPoint {
                CGPoint(x: cx + sin(p * 1.8) * reach, y: cy + cos(p * 2.4) * lift)
            }

            var trail = Path()
            let points = 24
            for i in 0..<points {
                let t = Double(i) / Double(points - 1)
                let point = position(hudPhase - t * 0.8)
                if i == 0 { trail.move(to: point) } else { trail.addLine(to: point) }
            }

            let head = position(hudPhase)
            let lineWidth = (4 + level * 4) * plate
            canvas.glowStroke(trail, hudRGB(56, 189, 248, 0.7), radius: 5 * plate, lineWidth: lineWidth)
            canvas.stroke(trail, with: .linearGradient(
                Gradient(colors: [hudRGB(56, 189, 248, 0.95), hudRGB(129, 140, 248, 0.6), hudRGB(99, 102, 241, 0)]),
                startPoint: head, endPoint: CGPoint(x: cx, y: cy)
            ), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            let headR = max(3 * plate, (4 + level * 3) * plate)
            let headPath = Path(ellipseIn: CGRect(x: head.x - headR, y: head.y - headR,
                                                  width: headR * 2, height: headR * 2))
            canvas.glowFill(headPath, .white.opacity(0.85), radius: 6 * plate)
            canvas.fill(headPath, with: .color(.white))
        }
    }
}

/// "雙螺旋" -- thicker strands with bright crossing nodes so the braid reads at
/// small size instead of dissolving into two hairlines.
struct HelixBraid: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let points = 32

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let cy = h / 2
            let step = w / Double(Self.points - 1)

            for strand in 0..<2 {
                let offset = Double(strand) * .pi
                let hue: Double = strand == 0 ? 190 : 280

                func y(at x: Double) -> Double {
                    let normX = (x - w / 2) / (w / 2)
                    let envelope = cos(normX * .pi * 0.45)
                    return cy + sin(hudPhase * 2 + normX * 3 + offset)
                        * (h * 0.36 * (0.15 + level * 0.85)) * envelope
                }

                var path = Path()
                for i in 0..<Self.points {
                    let x = Double(i) * step
                    let point = CGPoint(x: x, y: y(at: x))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }

                let lineWidth = (3.5 + level * 2) * plate
                canvas.glowStroke(path, hudHSL(hue, 0.95, 0.6, 0.7), radius: (4 + level * 3) * plate,
                                  lineWidth: lineWidth)
                canvas.stroke(path, with: .color(hudHSL(hue, 0.95, 0.68)),
                              style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                var i = 2
                while i < Self.points - 2 {
                    let x = Double(i) * step
                    let r = (2.2 + level * 1.2) * plate
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y(at: x) - r, width: r * 2, height: r * 2)),
                        with: .color(.white)
                    )
                    i += 5
                }
            }
        }
    }
}

/// "水銀" -- the roster's strongest survivor, refined: a mirrored liquid band
/// with a bright upper reflection.
struct MercuryBand: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let steps = 30

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let cy = h / 2
            let stepW = w / Double(Self.steps)

            func offset(at x: Double) -> Double {
                let normX = (x - w / 2) / (w / 2)
                let envelope = cos(normX * .pi * 0.4)
                let wave = sin(hudPhase * 1.6 + normX * 2.5) * cos(hudPhase * 0.9 + normX * 1.2)
                return abs(wave) * (4 * plate + level * (h * 0.36)) * envelope
            }

            var band = Path()
            band.move(to: CGPoint(x: 0, y: cy))
            for i in 0...Self.steps {
                let x = Double(i) * stepW
                band.addLine(to: CGPoint(x: x, y: cy - offset(at: x) - 2 * plate))
            }
            for i in stride(from: Self.steps, through: 0, by: -1) {
                let x = Double(i) * stepW
                band.addLine(to: CGPoint(x: x, y: cy + offset(at: x) + 2 * plate))
            }
            band.closeSubpath()

            canvas.glowFill(band, hudRGB(226, 232, 240, 0.5), radius: (4 + level * 3) * plate)
            canvas.fill(band, with: .linearGradient(
                Gradient(stops: [
                    .init(color: hudRGB(226, 232, 240), location: 0),
                    .init(color: hudRGB(148, 163, 184), location: 0.3),
                    .init(color: hudRGB(203, 213, 225), location: 0.7),
                    .init(color: hudRGB(100, 116, 139), location: 1),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: h)
            ))
            canvas.stroke(band, with: .color(.white),
                          style: StrokeStyle(lineWidth: 1.8 * plate, lineJoin: .round))
        }
    }
}

/// "電漿" -- a wide violet discharge with a bright inner filament, replacing a
/// single thin blue line that carried no character.
struct PlasmaArc: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let cy = h / 2

            var arc = Path()
            var x = 0.0
            while x <= w {
                let normX = (x - w / 2) / (w / 2)
                let envelope = exp(-normX * normX * 3)
                let swing = sin(hudPhase * 3 + normX * 5) * 8 * plate
                    + cos(hudPhase * 2 - normX * 8) * 6 * plate
                let y = cy + swing * (0.2 + level * 0.8) * envelope
                if x == 0 { arc.move(to: CGPoint(x: x, y: y)) } else { arc.addLine(to: CGPoint(x: x, y: y)) }
                x += 3 * plate
            }

            let outerWidth = (6 + level * 4) * plate
            canvas.glowStroke(arc, hudRGB(168, 85, 247, 0.75), radius: (6 + level * 4) * plate,
                              lineWidth: outerWidth)
            canvas.stroke(arc, with: .color(hudRGB(168, 85, 247, 0.8)),
                          style: StrokeStyle(lineWidth: outerWidth, lineCap: .round, lineJoin: .round))
            canvas.glowStroke(arc, .white.opacity(0.6), radius: 3 * plate, lineWidth: 2.5 * plate)
            canvas.stroke(arc, with: .color(hudRGB(192, 132, 252)),
                          style: StrokeStyle(lineWidth: 2.5 * plate, lineCap: .round, lineJoin: .round))
        }
    }
}

/// "日蝕" -- the hard orange ring is replaced by erupting prominences over a
/// soft halo, so the frame reading is gone.
struct EclipseCorona: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let rays = 16

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let cx = w / 2, cy = h / 2
            let r = min(w, h) * 0.32

            for i in 0..<Self.rays {
                let angle = (Double(i) / Double(Self.rays)) * .pi * 2 + hudPhase * 0.5
                let noise = sin(hudPhase * 3 + Double(i) * 1.7) * 0.3 + 0.7
                let rayLength = r * (1.2 + (level * 0.9 + 0.1) * noise * 0.8)
                let end = CGPoint(x: cx + cos(angle) * rayLength, y: cy + sin(angle) * rayLength)
                var ray = Path()
                ray.move(to: CGPoint(x: cx, y: cy))
                ray.addLine(to: end)
                canvas.stroke(ray, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: hudRGB(251, 191, 36, 0.9), location: 0),
                        .init(color: hudRGB(245, 158, 11, 0.5), location: 0.6),
                        .init(color: hudRGB(217, 119, 6, 0), location: 1),
                    ]),
                    startPoint: CGPoint(x: cx, y: cy), endPoint: end
                ), style: StrokeStyle(lineWidth: (3 + level * 2) * plate, lineCap: .round))
            }

            let haloR = r * (1.05 + level * 0.25) * 1.4
            canvas.fill(
                Path(ellipseIn: CGRect(x: cx - haloR, y: cy - haloR, width: haloR * 2, height: haloR * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: hudRGB(254, 240, 138), location: 0),
                        .init(color: hudRGB(245, 158, 11), location: 0.5),
                        .init(color: hudRGB(180, 83, 9, 0), location: 1),
                    ]),
                    center: CGPoint(x: cx, y: cy), startRadius: r * 0.8, endRadius: haloR
                )
            )

            let disc = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            canvas.fill(disc, with: .color(hudRGB(13, 14, 18)))
            canvas.stroke(disc, with: .color(hudRGB(254, 240, 138, 0.8)),
                          style: StrokeStyle(lineWidth: 1.2 * plate))
        }
    }
}

// MARK: - Organic pack (smoke / water)

/// "煙霧" -- overlapping radial blobs orbiting a centre, screened together so
/// they read as one churning volume rather than seven circles.
struct SmokePlume: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let blobs = 7

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let cx = w / 2, cy = h * 0.55
            let baseRadius = min(w, h) * (0.28 + level * 0.25)

            canvas.drawLayer { layer in
                layer.blendMode = .screen
                for i in 0..<Self.blobs {
                    let angle = hudPhase * (0.4 + Double(i) * 0.15)
                        + (Double(i) * .pi * 2) / Double(Self.blobs)
                    let drift = (12 * plate + level * 28 * plate)
                        * (0.5 + 0.5 * sin(hudPhase * 0.8 + Double(i)))
                    let bx = cx + cos(angle) * drift
                    let by = cy + sin(angle * 1.3) * (drift * 0.5) - level * 10 * plate
                    let radius = baseRadius * (0.7 + 0.4 * sin(hudPhase + Double(i) * 1.7))
                    guard radius > 0 else { continue }
                    let alpha = 0.22 + level * 0.35
                    layer.fill(
                        Path(ellipseIn: CGRect(x: bx - radius, y: by - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: hudRGB(165, 180, 252, alpha), location: 0),
                                .init(color: hudRGB(99, 102, 241, alpha * 0.65), location: 0.45),
                                .init(color: hudRGB(79, 70, 229, alpha * 0.2), location: 0.8),
                                .init(color: hudRGB(15, 23, 42, 0), location: 1),
                            ]),
                            center: CGPoint(x: bx, y: by), startRadius: 0, endRadius: radius
                        )
                    )
                }
            }
        }
    }
}

/// "橫煙" -- four stacked drifting bands, the horizontal counterpart to the
/// plume: a stream pulled sideways by airflow.
struct HorizontalSmoke: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let layers = 4

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0
            let centerY = h * 0.5

            canvas.drawLayer { context in
                context.blendMode = .screen
                for l in 0..<Self.layers {
                    let amplitude = (6 * plate + level * 16 * plate) * (1 - Double(l) * 0.18)
                    let frequency = 0.03 + Double(l) * 0.01
                    let speed = hudPhase * (0.8 + Double(l) * 0.3)
                    var band = Path()
                    band.move(to: CGPoint(x: 0, y: h))
                    var x = 0.0
                    while x <= w {
                        let wave = sin(x * frequency / plate + speed) * cos(x * 0.015 / plate - speed * 0.5)
                        let y = centerY + wave * amplitude + (Double(l) - 1.5) * 4 * plate
                        band.addLine(to: CGPoint(x: x, y: y))
                        x += 4 * plate
                    }
                    band.addLine(to: CGPoint(x: w, y: h))
                    band.closeSubpath()

                    let alpha = 0.25 + level * 0.35 - Double(l) * 0.04
                    context.fill(band, with: .linearGradient(
                        Gradient(stops: [
                            .init(color: hudRGB(192, 132, 252, alpha), location: 0),
                            .init(color: hudRGB(129, 140, 248, alpha * 0.8), location: 0.5),
                            .init(color: hudRGB(15, 23, 42, 0), location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: centerY - amplitude),
                        endPoint: CGPoint(x: 0, y: centerY + amplitude + 10 * plate)
                    ))
                }
            }
        }
    }
}

/// "海浪" -- three stacked swells seen side-on, the front one carrying a
/// specular foam line that only appears once there is something to hear.
struct OceanSwell: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let waves = 3

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0

            for i in (0..<Self.waves).reversed() {
                let baseHeight = h * (0.55 + Double(i) * 0.08)
                let amplitude = (4 * plate + level * 16 * plate) * (1 - Double(i) * 0.2)
                let speed = hudPhase * (1.0 + Double(i) * 0.4)

                var crestLine = Path()
                var body = Path()
                body.move(to: CGPoint(x: 0, y: h))
                var x = 0.0
                var first = true
                while x <= w {
                    let normX = x / w
                    let crest = sin(normX * .pi * 3 + speed) * amplitude
                    let detail = cos(normX * .pi * 7 - speed * 1.5) * (amplitude * 0.35)
                    let point = CGPoint(x: x, y: baseHeight + crest + detail)
                    body.addLine(to: point)
                    if first { crestLine.move(to: point); first = false } else { crestLine.addLine(to: point) }
                    x += 3 * plate
                }
                body.addLine(to: CGPoint(x: w, y: h))
                body.closeSubpath()

                let stops: [Gradient.Stop]
                if i == 0 {
                    stops = [.init(color: hudRGB(56, 189, 248, 0.7 + level * 0.3), location: 0),
                             .init(color: hudRGB(14, 165, 233, 0.4 + level * 0.4), location: 0.4),
                             .init(color: hudRGB(3, 105, 161, 0.1), location: 1)]
                } else if i == 1 {
                    stops = [.init(color: hudRGB(129, 140, 248, 0.5 + level * 0.3), location: 0),
                             .init(color: hudRGB(30, 27, 75, 0.2), location: 1)]
                } else {
                    stops = [.init(color: hudRGB(99, 102, 241, 0.35 + level * 0.25), location: 0),
                             .init(color: hudRGB(15, 23, 42, 0.3), location: 1)]
                }
                canvas.fill(body, with: .linearGradient(
                    Gradient(stops: stops),
                    startPoint: CGPoint(x: 0, y: baseHeight - amplitude - 5 * plate),
                    endPoint: CGPoint(x: 0, y: h)
                ))

                if i == 0, level > 0.05 {
                    canvas.stroke(crestLine, with: .color(hudRGB(224, 242, 254, 0.4 + level * 0.5)),
                                  style: StrokeStyle(lineWidth: 1.8 * plate, lineCap: .round))
                }
            }
        }
    }
}

/// "絲綢氣流" -- three overlapping ribbons of coloured light, screened so the
/// crossings brighten the way real silk catches a highlight.
struct SilkStream: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let ribbons = 3

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0

            canvas.drawLayer { context in
                context.blendMode = .screen
                for r in 0..<Self.ribbons {
                    let offsetPhase = hudPhase + Double(r) * 1.2
                    let amp = (6 * plate + level * 14 * plate)
                    var ribbon = Path()
                    var x = 0.0
                    var first = true
                    while x <= w {
                        let t = x / w
                        let y = h * 0.5 + sin(t * 5 + offsetPhase) * amp
                            + cos(t * 3 - offsetPhase * 0.7) * (amp * 0.5)
                        if first { ribbon.move(to: CGPoint(x: x, y: y)); first = false }
                        else { ribbon.addLine(to: CGPoint(x: x, y: y)) }
                        x += 4 * plate
                    }
                    x = w
                    while x >= 0 {
                        let t = x / w
                        let y = h * 0.5 + sin(t * 5 + offsetPhase + 0.4) * (amp * 1.1)
                            + cos(t * 3 - offsetPhase * 0.7) * (amp * 0.4) + (8 * plate + level * 8 * plate)
                        ribbon.addLine(to: CGPoint(x: x, y: y))
                        x -= 4 * plate
                    }
                    ribbon.closeSubpath()

                    let alpha = 0.25 + level * 0.35
                    let colors: [Color]
                    if r == 0 {
                        colors = [hudRGB(236, 72, 153, alpha), hudRGB(139, 92, 246, alpha)]
                    } else if r == 1 {
                        colors = [hudRGB(99, 102, 241, alpha), hudRGB(45, 212, 191, alpha)]
                    } else {
                        colors = [hudRGB(168, 85, 247, alpha * 0.8), hudRGB(244, 63, 94, alpha * 0.8)]
                    }
                    context.fill(ribbon, with: .linearGradient(
                        Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: w, y: h)
                    ))
                }
            }
        }
    }
}

/// "極光霧" -- stacked curtains fading downward; the aurora read without the
/// hard edges of the original ribbon.
struct AuroraMist: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let bands = 4

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0

            canvas.drawLayer { context in
                context.blendMode = .screen
                for b in 0..<Self.bands {
                    let p = hudPhase * (0.6 + Double(b) * 0.2)
                    let amp = 8 * plate + level * 18 * plate
                    var curtain = Path()
                    curtain.move(to: CGPoint(x: 0, y: 0))
                    var x = 0.0
                    while x <= w {
                        let normX = x / w
                        let y = h * 0.4 + sin(normX * 4 + p) * amp
                            + sin(normX * 8 - p * 1.2) * (amp * 0.4) + Double(b) * 4 * plate
                        curtain.addLine(to: CGPoint(x: x, y: y))
                        x += 4 * plate
                    }
                    curtain.addLine(to: CGPoint(x: w, y: h))
                    curtain.addLine(to: CGPoint(x: 0, y: h))
                    curtain.closeSubpath()

                    let alpha = 0.2 + level * 0.35
                    let stops: [Gradient.Stop] = b.isMultiple(of: 2)
                        ? [.init(color: hudRGB(52, 211, 153, alpha), location: 0),
                           .init(color: hudRGB(99, 102, 241, alpha * 0.7), location: 0.5),
                           .init(color: hudRGB(15, 23, 42, 0), location: 1)]
                        : [.init(color: hudRGB(167, 139, 250, alpha), location: 0),
                           .init(color: hudRGB(56, 189, 248, alpha * 0.6), location: 0.6),
                           .init(color: hudRGB(15, 23, 42, 0), location: 1)]
                    context.fill(curtain, with: .linearGradient(
                        Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
                    ))
                }
            }
        }
    }
}

/// "墨滴擴散" -- five ink drops blooming in water. Positions are seeded from
/// the index, never randomised, so the shape is identical every launch.
struct InkBloom: View {
    @Environment(\.hudPhase) private var hudPhase
    let levels: [Double]

    private static let drops = 5

    /// Deterministic stand-in for the prototype's seeded random.
    private func seeded(_ seed: Double) -> Double {
        let x = sin(seed) * 10_000
        return x - x.rounded(.down)
    }

    var body: some View {
        Canvas { canvas, size in
            let w = Double(size.width), h = Double(size.height)
            let plate = w / hudReferenceWidth
            let level = levels.last ?? 0

            canvas.drawLayer { context in
                context.blendMode = .screen
                for d in 0..<Self.drops {
                    let seed = Double(d) * 17 + 3
                    let cx = w * (0.2 + 0.6 * seeded(seed))
                    let cy = h * 0.5 + (seeded(seed + 1) - 0.5) * 12 * plate
                    let pulse = sin(hudPhase * 0.8 + Double(d) * 1.5) * 0.5 + 0.5
                    let radius = (12 * plate + level * 26 * plate) * (0.6 + 0.4 * pulse)
                    guard radius > 0 else { continue }

                    let alpha = 0.3 + level * 0.4
                    let tint: [Gradient.Stop]
                    switch d % 3 {
                    case 0:
                        tint = [.init(color: hudRGB(129, 140, 248, alpha), location: 0),
                                .init(color: hudRGB(79, 70, 229, alpha * 0.5), location: 0.5)]
                    case 1:
                        tint = [.init(color: hudRGB(192, 132, 252, alpha), location: 0),
                                .init(color: hudRGB(147, 51, 234, alpha * 0.5), location: 0.5)]
                    default:
                        tint = [.init(color: hudRGB(56, 189, 248, alpha), location: 0),
                                .init(color: hudRGB(2, 132, 199, alpha * 0.5), location: 0.5)]
                    }
                    context.fill(
                        Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .radialGradient(
                            Gradient(stops: tint + [.init(color: hudRGB(15, 23, 42, 0), location: 1)]),
                            center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: radius
                        )
                    )
                }
            }
        }
    }
}
