import Foundation

enum VoiceMode: String, CaseIterable, Codable, Sendable {
    case dictate
    case translate
    case ask

    var displayName: String {
        switch self { case .dictate: "聽寫"; case .translate: "翻譯"; case .ask: "隨便問" }
    }
}

enum HUDStyle: String, CaseIterable, Codable, Sendable {
    case classicBars
    case siriOrb
    case waterLine
    case minimalDots
    case precisionWaveform
    case quantumOrb
    case minimalistRipple
    case amberResonance
    case pencilSketch
    case zenIncense

    var displayName: String {
        switch self {
        case .classicBars: "柱狀顯示"
        case .siriOrb: "Siri 光球"
        case .waterLine: "流動波形"
        case .minimalDots: "極簡圓點"
        case .precisionWaveform: "精準頻譜"
        case .quantumOrb: "量子光球"
        case .minimalistRipple: "極簡聲波"
        case .amberResonance: "木質暖香"
        case .pencilSketch: "優雅素描"
        case .zenIncense: "裊裊輕煙"
        }
    }
}

/// Visual treatment for the live-caption text itself (separate from HUDStyle,
/// which only controls the small waveform/orb indicator). `.bubble` is the
/// original single-capsule design and stays the default -- these are
/// additional choices, not replacements.
enum SubtitleStyle: String, CaseIterable, Codable, Sendable {
    case bubble
    case fluidGlow
    case teleprompter
    case terminal
    case spatialBlur

    var displayName: String {
        switch self {
        case .bubble: "膠囊字幕"
        case .fluidGlow: "流動光暈"
        case .teleprompter: "提詞機"
        case .terminal: "終端機打字"
        case .spatialBlur: "空間焦距模糊"
        }
    }
}

struct ProductPreferences: Codable, Equatable, Sendable {
    var dictate: HotkeyProfile = .defaultProfile
    var translate: HotkeyProfile = HotkeyProfile(trigger: .leftCommand, behavior: .toggle)
    var ask: HotkeyProfile = HotkeyProfile(trigger: .function, behavior: .toggle)
    var interfaceLanguage = "繁體中文（台灣）"
    var translationTarget = "英語（美國）"
    var interactionSounds = true
    var muteOtherAudio = true
    var showDockIcon = true
    var hudStyle: HUDStyle = .classicBars
    var liveCaptionsEnabled = true
    var subtitleStyle: SubtitleStyle = .bubble

    private enum CodingKeys: String, CodingKey {
        case dictate, translate, ask, interfaceLanguage, translationTarget
        case interactionSounds, muteOtherAudio, showDockIcon
        case hudStyle, liveCaptionsEnabled, subtitleStyle
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dictate = try values.decodeIfPresent(HotkeyProfile.self, forKey: .dictate) ?? .defaultProfile
        translate = try values.decodeIfPresent(HotkeyProfile.self, forKey: .translate)
            ?? HotkeyProfile(trigger: .leftCommand, behavior: .toggle)
        ask = try values.decodeIfPresent(HotkeyProfile.self, forKey: .ask)
            ?? HotkeyProfile(trigger: .function, behavior: .toggle)
        interfaceLanguage = try values.decodeIfPresent(String.self, forKey: .interfaceLanguage) ?? "繁體中文（台灣）"
        translationTarget = try values.decodeIfPresent(String.self, forKey: .translationTarget) ?? "英語（美國）"
        interactionSounds = try values.decodeIfPresent(Bool.self, forKey: .interactionSounds) ?? true
        muteOtherAudio = try values.decodeIfPresent(Bool.self, forKey: .muteOtherAudio) ?? true
        showDockIcon = try values.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        hudStyle = try values.decodeIfPresent(HUDStyle.self, forKey: .hudStyle) ?? .classicBars
        liveCaptionsEnabled = try values.decodeIfPresent(Bool.self, forKey: .liveCaptionsEnabled) ?? true
        subtitleStyle = try values.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? .bubble
    }
}

enum ProductPreferencesStore {
    private static let key = "nexvoice.product.preferences"
    static func load(_ defaults: UserDefaults = .standard) -> ProductPreferences {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(ProductPreferences.self, from: data)
        else { return ProductPreferences() }
        return value
    }
    static func save(_ value: ProductPreferences, _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
