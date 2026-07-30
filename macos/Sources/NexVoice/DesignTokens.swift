import AppKit
import SwiftUI

/// A full set of NV tokens for one app theme.
struct NVPalette {
    let bg, sidebar, card, glassOverlay, ink, secondary, hairline, selected: Color
    /// Neutral raised/inset fills. These must be theme-owned rather than a
    /// hard-coded black wash — on a dark theme a black overlay reads as a hole
    /// punched in the card instead of a raised control.
    let fill, fillStrong: Color
    let blue, cyan, purple, cream, charcoal, ok, warn, recording: Color
    let brandGradientColors: [Color]
    let waveGradientColors: [Color]
}

private let nvPristinePalette = NVPalette(
    bg: Color(red: 0.965, green: 0.968, blue: 0.975), // Crisp Clean Slate
    sidebar: Color(red: 0.945, green: 0.950, blue: 0.958),
    card: Color.white,
    glassOverlay: Color.black.opacity(0.03),
    ink: Color(red: 0.11, green: 0.12, blue: 0.16),
    secondary: Color(red: 0.48, green: 0.52, blue: 0.60),
    hairline: Color.black.opacity(0.08),
    selected: Color(red: 0.90, green: 0.92, blue: 0.96),
    fill: Color.black.opacity(0.04),
    fillStrong: Color.black.opacity(0.08),
    blue: Color(red: 0.22, green: 0.45, blue: 0.98), // Electric Royal Blue
    cyan: Color(red: 0.05, green: 0.68, blue: 0.82),
    purple: Color(red: 0.55, green: 0.28, blue: 0.92),
    cream: Color(red: 0.98, green: 0.95, blue: 0.90),
    charcoal: Color(red: 0.15, green: 0.16, blue: 0.20),
    ok: Color(red: 0.12, green: 0.68, blue: 0.42),
    warn: Color(red: 0.92, green: 0.52, blue: 0.12),
    recording: Color(red: 0.92, green: 0.22, blue: 0.32),
    brandGradientColors: [
        Color(red: 0.22, green: 0.45, blue: 0.98),
        Color(red: 0.42, green: 0.35, blue: 0.96),
    ],
    waveGradientColors: [
        Color(red: 0.05, green: 0.68, blue: 0.82),
        Color(red: 0.22, green: 0.45, blue: 0.98),
        Color(red: 0.55, green: 0.28, blue: 0.92),
    ]
)

/// ChatGPT design-lab warm paper look.
private let nvStudioPalette = NVPalette(
    bg: Color(red: 0.933, green: 0.906, blue: 0.863),
    sidebar: Color(red: 0.914, green: 0.882, blue: 0.835),
    card: Color(red: 0.976, green: 0.961, blue: 0.933),
    glassOverlay: Color.black.opacity(0.03),
    ink: Color(red: 0.188, green: 0.180, blue: 0.165),
    secondary: Color(red: 0.557, green: 0.529, blue: 0.486),
    hairline: Color(red: 0.184, green: 0.176, blue: 0.161).opacity(0.11),
    selected: Color(red: 0.882, green: 0.845, blue: 0.784),
    fill: Color(red: 0.184, green: 0.176, blue: 0.161).opacity(0.055),
    fillStrong: Color(red: 0.184, green: 0.176, blue: 0.161).opacity(0.10),
    blue: Color(red: 0.365, green: 0.471, blue: 0.427), // moss (primary accent)
    cyan: Color(red: 0.459, green: 0.584, blue: 0.541), // sage
    purple: Color(red: 0.655, green: 0.396, blue: 0.369), // terracotta
    cream: Color(red: 0.976, green: 0.961, blue: 0.933),
    charcoal: Color(red: 0.188, green: 0.180, blue: 0.165),
    ok: Color(red: 0.306, green: 0.490, blue: 0.357),
    warn: Color(red: 0.690, green: 0.502, blue: 0.247),
    recording: Color(red: 0.655, green: 0.396, blue: 0.369),
    brandGradientColors: [
        Color(red: 0.365, green: 0.471, blue: 0.427),
        Color(red: 0.459, green: 0.584, blue: 0.541),
    ],
    waveGradientColors: [
        Color(red: 0.459, green: 0.584, blue: 0.541),
        Color(red: 0.365, green: 0.471, blue: 0.427),
        Color(red: 0.655, green: 0.396, blue: 0.369),
    ]
)

/// Design-lab dark twin of `studio`.
private let nvObsidianPalette = NVPalette(
    // bg sits well below card so surfaces separate without needing a border --
    // at the original 0.090/0.125 pairing the cards dissolved into the canvas.
    bg: Color(red: 0.071, green: 0.078, blue: 0.086),
    sidebar: Color(red: 0.051, green: 0.058, blue: 0.066),
    card: Color(red: 0.133, green: 0.145, blue: 0.157),
    glassOverlay: Color.white.opacity(0.04),
    ink: Color(red: 0.941, green: 0.929, blue: 0.910),
    secondary: Color(red: 0.608, green: 0.604, blue: 0.592),
    hairline: Color.white.opacity(0.10),
    selected: Color(red: 0.176, green: 0.192, blue: 0.204),
    fill: Color.white.opacity(0.07),
    fillStrong: Color.white.opacity(0.12),
    blue: Color(red: 0.310, green: 0.820, blue: 0.710), // teal accent
    cyan: Color(red: 0.494, green: 0.910, blue: 0.839),
    purple: Color(red: 0.592, green: 0.541, blue: 1.0), // violet
    cream: Color(red: 0.125, green: 0.137, blue: 0.149),
    charcoal: Color(red: 0.941, green: 0.929, blue: 0.910),
    ok: Color(red: 0.310, green: 0.820, blue: 0.710),
    warn: Color(red: 0.910, green: 0.655, blue: 0.361),
    recording: Color(red: 1.0, green: 0.420, blue: 0.478),
    brandGradientColors: [
        Color(red: 0.310, green: 0.820, blue: 0.710),
        Color(red: 0.592, green: 0.541, blue: 1.0),
    ],
    waveGradientColors: [
        Color(red: 0.494, green: 0.910, blue: 0.839),
        Color(red: 0.310, green: 0.820, blue: 0.710),
        Color(red: 0.592, green: 0.541, blue: 1.0),
    ]
)

extension AppTheme {
    /// Drives SwiftUI's own controls (Toggle, Picker, TextField, Divider…).
    /// Without this the dark theme renders every native control in light
    /// appearance on top of a near-black card.
    var colorScheme: ColorScheme { self == .obsidian ? .dark : .light }

    /// Drives the AppKit window chrome — titlebar and traffic lights — which
    /// `preferredColorScheme` does not reach.
    var nsAppearance: NSAppearance? {
        NSAppearance(named: self == .obsidian ? .darkAqua : .aqua)
    }
}

/// Pushes the theme onto the hosting NSWindow so the titlebar matches the
/// content instead of staying permanently light.
private struct NVWindowAppearance: NSViewRepresentable {
    let theme: AppTheme

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let appearance = theme.nsAppearance
        DispatchQueue.main.async { nsView.window?.appearance = appearance }
    }
}

extension View {
    /// Apply on any top-level window content: syncs both the SwiftUI color
    /// scheme and the AppKit window chrome to the app theme.
    func nvTheme(_ theme: AppTheme) -> some View {
        preferredColorScheme(theme.colorScheme)
            .background(NVWindowAppearance(theme: theme).frame(width: 0, height: 0))
    }
}

private func palette(for theme: AppTheme) -> NVPalette {
    switch theme {
    case .pristine: nvPristinePalette
    case .studio: nvStudioPalette
    case .obsidian: nvObsidianPalette
    }
}

/// Swatch colors for a theme-picker preview card, independent of `NV.theme`
/// (which reflects only the currently-applied theme, not the one being
/// previewed in the picker).
func nvPreviewPalette(for theme: AppTheme) -> (bg: Color, card: Color, accent: Color) {
    let p = palette(for: theme)
    return (p.bg, p.card, p.blue)
}

/// Premium Light Glass & Modern Minimal Palette for NexVoice UI Redesign
enum NV {
    /// Set from AppModel on the main thread whenever the theme preference
    /// changes; SwiftUI re-reads every token on the forced root rebuild.
    nonisolated(unsafe) static var theme: AppTheme = .pristine
    private static var p: NVPalette { palette(for: theme) }

    // Canvas & Surface Colors
    static var bg: Color { p.bg }
    static var sidebar: Color { p.sidebar }
    static var card: Color { p.card }
    static var glassOverlay: Color { p.glassOverlay }

    // Typography & Ink
    static var ink: Color { p.ink }
    static var secondary: Color { p.secondary }
    static var hairline: Color { p.hairline }
    static var selected: Color { p.selected }
    static var fill: Color { p.fill }
    static var fillStrong: Color { p.fillStrong }

    // Accents
    static var blue: Color { p.blue }
    static var cyan: Color { p.cyan }
    static var purple: Color { p.purple }
    static var cream: Color { p.cream }
    static var charcoal: Color { p.charcoal }

    // Status Accents
    static var ok: Color { p.ok }
    static var warn: Color { p.warn }
    static var recording: Color { p.recording }

    // Corner Radius
    static let radius: CGFloat = 16
    static let radiusSm: CGFloat = 10

    // Gradients
    static var brandGradient: LinearGradient {
        LinearGradient(colors: p.brandGradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var waveGradient: LinearGradient {
        LinearGradient(colors: p.waveGradientColors, startPoint: .leading, endPoint: .trailing)
    }
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
                configuration.isPressed ? NV.fillStrong : NV.fill,
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

