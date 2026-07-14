import AppKit
import SwiftUI

/// Pure SwiftUI paint — never depends on bundle PNG/icns (those were blank in UI).
struct NexVoiceMark: View {
    var size: CGFloat = 42
    var active: Bool = true

    private let cream = Color(red: 0.96, green: 0.925, blue: 0.88)
    private let charcoal = Color(red: 0.14, green: 0.14, blue: 0.13)
    private let ink = Color(red: 0.99, green: 0.98, blue: 0.97)
    private let bars: [CGFloat] = [0.28, 0.52, 0.82, 1.0, 0.76, 0.48, 0.30]

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let origin = CGPoint(x: (canvasSize.width - s) / 2, y: (canvasSize.height - s) / 2)
            let outer = CGRect(x: origin.x, y: origin.y, width: s, height: s)

            // Cream tile
            context.fill(
                Path(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), cornerRadius: s * 0.22),
                with: .color(cream)
            )
            // Charcoal chalk
            let inset = s * 0.12
            let inner = outer.insetBy(dx: inset, dy: inset)
            context.fill(
                Path(roundedRect: inner, cornerRadius: s * 0.16),
                with: .color(charcoal)
            )
            // Waveform bars
            let gap = s * 0.09
            let total = CGFloat(bars.count - 1) * gap
            let x0 = outer.midX - total / 2
            let maxH = s * 0.40
            let w = max(2.0, s * 0.07)
            for (i, amp) in bars.enumerated() {
                let h = maxH * amp
                let x = x0 + CGFloat(i) * gap
                let bar = CGRect(x: x - w / 2, y: outer.midY - h / 2, width: w, height: h)
                context.fill(Path(roundedRect: bar, cornerRadius: w / 2), with: .color(ink))
            }
        }
        .frame(width: size, height: size)
        .opacity(active ? 1 : 0.75)
        .accessibilityLabel("NexVoice")
    }
}

struct DrawnNexVoiceMark: View {
    var size: CGFloat = 42
    var body: some View { NexVoiceMark(size: size) }
}

struct MenuBarLabel: View {
    let isEnabled: Bool

    var body: some View {
        NexVoiceMark(size: 18, active: isEnabled)
            .accessibilityLabel(isEnabled ? "NexVoice 已啟用" : "NexVoice 已停用")
    }
}
