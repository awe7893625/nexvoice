import Foundation

enum VoiceMode: String, CaseIterable, Codable, Sendable {
    case dictate
    case translate
    case ask

    var displayName: String {
        switch self { case .dictate: "聽寫"; case .translate: "翻譯"; case .ask: "隨便問" }
    }
}

/// Retired 2026-07-25: ink/spectrum/floatVoice/ekg/
/// silk/cascade/meteor were all variations on a thin pale line or a scatter of
/// dim dots -- the two things that read as unfinished on a black capsule.
/// Stale rawValues decode back to `.glassBars`, so removing them cannot
/// corrupt an existing preferences blob.
enum HUDStyle: String, CaseIterable, Codable, Sendable {
    case glassBars
    case bloomPills
    case plasmaColumns
    case liquidPulse
    case auraRibbon
    case glass
    case aurora
    case siri
    case prismCore
    case ember
    case comet
    case helix
    case mercury
    case plasma
    case eclipse
    case smoke
    case horizontalSmoke
    case oceanSwell
    case silkStream
    case auroraMist
    case inkBloom

    var displayName: String {
        switch self {
        case .glassBars: "亮條"
        case .bloomPills: "膠囊光暈"
        case .plasmaColumns: "等離子柱"
        case .liquidPulse: "液態脈衝"
        case .auraRibbon: "流光絲帶"
        case .glass: "琉璃"
        case .aurora: "極光"
        case .siri: "光球"
        case .prismCore: "虹核"
        case .ember: "赤霞"
        case .comet: "彗尾"
        case .helix: "雙螺旋"
        case .mercury: "水銀"
        case .plasma: "電漿"
        case .eclipse: "日蝕"
        case .smoke: "煙霧"
        case .horizontalSmoke: "橫煙"
        case .oceanSwell: "海浪"
        case .silkStream: "絲綢氣流"
        case .auroraMist: "極光霧"
        case .inkBloom: "墨滴擴散"
        }
    }
}

/// Chrome (frame treatment) for the compact HUD capsule, orthogonal to
/// HUDStyle: any waveform can wear any frame.
enum HUDChrome: String, CaseIterable, Codable, Sendable {
    case borderless
    case hairline
    case glowEdge
    case breathingRing
    case naked
    case aura
    case emboss

    var displayName: String {
        switch self {
        case .borderless: "無邊框"
        case .hairline: "髮絲細邊"
        case .glowEdge: "流光邊"
        case .breathingRing: "呼吸光環"
        case .naked: "超薄無底"
        case .aura: "微光流體"
        case .emboss: "浮雕"
        }
    }
}

/// Overall app window theme. `pristine` is the original light UI; `studio`
/// mirrors the ChatGPT design-lab warm paper look; `obsidian` is its dark twin.
enum AppTheme: String, CaseIterable, Codable, Sendable {
    case pristine
    case studio
    case obsidian

    var displayName: String {
        switch self {
        case .pristine: "純淨"
        case .studio: "設計工房"
        case .obsidian: "曜石"
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
    var fillerWordCleanupEnabled = true
    var selfCorrectionCleanupEnabled = true
    var hudStyle: HUDStyle = .glassBars
    var hudChrome: HUDChrome = .borderless
    var liveCaptionsEnabled = true
    var subtitleStyle: SubtitleStyle = .bubble
    var appTheme: AppTheme = .pristine

    private enum CodingKeys: String, CodingKey {
        case dictate, translate, ask, interfaceLanguage, translationTarget
        case interactionSounds, muteOtherAudio, showDockIcon
        case fillerWordCleanupEnabled, selfCorrectionCleanupEnabled
        case hudStyle, hudChrome, liveCaptionsEnabled, subtitleStyle, appTheme
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
        fillerWordCleanupEnabled = try values.decodeIfPresent(Bool.self, forKey: .fillerWordCleanupEnabled) ?? true
        selfCorrectionCleanupEnabled = try values.decodeIfPresent(Bool.self, forKey: .selfCorrectionCleanupEnabled) ?? true
        // Decode as raw String first so a stale rawValue from a retired case
        // (e.g. a HUDStyle that no longer exists) falls back to the default
        // instead of throwing and zeroing out every other preference.
        if let rawHudStyle = try values.decodeIfPresent(String.self, forKey: .hudStyle) {
            hudStyle = HUDStyle(rawValue: rawHudStyle) ?? .glassBars
        } else {
            hudStyle = .glassBars
        }
        if let rawHudChrome = try values.decodeIfPresent(String.self, forKey: .hudChrome) {
            hudChrome = HUDChrome(rawValue: rawHudChrome) ?? .borderless
        } else {
            hudChrome = .borderless
        }
        liveCaptionsEnabled = try values.decodeIfPresent(Bool.self, forKey: .liveCaptionsEnabled) ?? true
        if let rawSubtitleStyle = try values.decodeIfPresent(String.self, forKey: .subtitleStyle) {
            subtitleStyle = SubtitleStyle(rawValue: rawSubtitleStyle) ?? .bubble
        } else {
            subtitleStyle = .bubble
        }
        if let rawAppTheme = try values.decodeIfPresent(String.self, forKey: .appTheme) {
            appTheme = AppTheme(rawValue: rawAppTheme) ?? .pristine
        } else {
            appTheme = .pristine
        }
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
