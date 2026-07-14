import SwiftUI

/// Light shell with NexPilot cream/charcoal brand accents.
enum NV {
    static let bg = Color(red: 0.973, green: 0.973, blue: 0.976) // #F8F8F9
    static let sidebar = Color(red: 0.965, green: 0.965, blue: 0.969)
    static let card = Color.white
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let secondary = Color(red: 0.45, green: 0.45, blue: 0.48)
    static let hairline = Color.black.opacity(0.06)
    static let selected = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let blue = Color(red: 0.20, green: 0.42, blue: 0.98) // Typeless-like CTA
    static let cream = Color(red: 0.96, green: 0.925, blue: 0.88)
    static let charcoal = Color(red: 0.165, green: 0.165, blue: 0.157)
    static let ok = Color(red: 0.18, green: 0.62, blue: 0.40)
    static let warn = Color(red: 0.90, green: 0.45, blue: 0.12)
    static let radius: CGFloat = 14
    static let radiusSm: CGFloat = 10
}

struct NVPrimaryButton: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                NV.blue.opacity(configuration.isPressed ? 0.75 : (enabled ? 1 : 0.4)),
                in: RoundedRectangle(cornerRadius: NV.radiusSm, style: .continuous)
            )
    }
}

struct NVSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(NV.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Color.black.opacity(configuration.isPressed ? 0.06 : 0.04),
                in: RoundedRectangle(cornerRadius: NV.radiusSm, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: NV.radiusSm, style: .continuous)
                    .stroke(NV.hairline, lineWidth: 1)
            }
    }
}

struct NVCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(NV.card, in: RoundedRectangle(cornerRadius: NV.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NV.radius, style: .continuous)
                    .stroke(NV.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func nvCard() -> some View { modifier(NVCardModifier()) }
}
