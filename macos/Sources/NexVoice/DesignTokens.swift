import SwiftUI

/// Premium Light Glass & Modern Minimal Palette for NexVoice UI Redesign
enum NV {
    // Canvas & Surface Colors (Pristine Light Theme)
    static let bg = Color(red: 0.965, green: 0.968, blue: 0.975) // Crisp Clean Slate
    static let sidebar = Color(red: 0.945, green: 0.950, blue: 0.958)
    static let card = Color.white
    static let glassOverlay = Color.black.opacity(0.03)
    
    // Typography & Ink
    static let ink = Color(red: 0.11, green: 0.12, blue: 0.16)
    static let secondary = Color(red: 0.48, green: 0.52, blue: 0.60)
    static let hairline = Color.black.opacity(0.08)
    static let selected = Color(red: 0.90, green: 0.92, blue: 0.96)
    
    // Modern Vibrant Accents
    static let blue = Color(red: 0.22, green: 0.45, blue: 0.98) // Electric Royal Blue
    static let cyan = Color(red: 0.05, green: 0.68, blue: 0.82)
    static let purple = Color(red: 0.55, green: 0.28, blue: 0.92)
    static let cream = Color(red: 0.98, green: 0.95, blue: 0.90)
    static let charcoal = Color(red: 0.15, green: 0.16, blue: 0.20)
    
    // Status Accents
    static let ok = Color(red: 0.12, green: 0.68, blue: 0.42)
    static let warn = Color(red: 0.92, green: 0.52, blue: 0.12)
    static let recording = Color(red: 0.92, green: 0.22, blue: 0.32)
    
    // Corner Radius
    static let radius: CGFloat = 16
    static let radiusSm: CGFloat = 10
    
    // Gradients
    static let brandGradient = LinearGradient(
        colors: [blue, Color(red: 0.42, green: 0.35, blue: 0.96)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let waveGradient = LinearGradient(
        colors: [cyan, blue, purple],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct NVPrimaryButton: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: NV.radiusSm, style: .continuous)
                    .fill(NV.brandGradient)
                    .opacity(configuration.isPressed ? 0.85 : (enabled ? 1 : 0.45))
                    .shadow(color: NV.blue.opacity(0.25), radius: 6, x: 0, y: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
                Color.black.opacity(configuration.isPressed ? 0.08 : 0.04),
                in: RoundedRectangle(cornerRadius: NV.radiusSm, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: NV.radiusSm, style: .continuous)
                    .stroke(NV.hairline, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct NVCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(
                NV.card,
                in: RoundedRectangle(cornerRadius: NV.radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: NV.radius, style: .continuous)
                    .stroke(NV.hairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func nvCard() -> some View { modifier(NVCardModifier()) }
}

