import Foundation

/// What a complete trigger gesture means to the recording state machine.
enum TriggerBehavior: String, CaseIterable, Codable, Equatable, Sendable {
    /// Press once to start recording and press again to stop.
    case toggle

    /// Start on key-down and stop on the matching key-up.
    case pushToTalk

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value {
        case Self.toggle.rawValue:
            self = .toggle
        case Self.pushToTalk.rawValue, "push-to-talk", "hold", "holdToTalk":
            self = .pushToTalk
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported trigger behavior: \(value)"
            )
        }
    }
}

/// A physical modifier key that can own the global voice trigger.
///
/// `option` intentionally means either physical Option key. The left/right
/// variants exist for users who want Typeless-style side-specific bindings.
/// Event monitoring and conflict detection belong to the runtime layer, not
/// this persistence model.
enum TriggerKey: String, CaseIterable, Codable, Equatable, Sendable {
    case option
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand
    case leftControl
    case rightControl
    case function

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value {
        case Self.option.rawValue, "eitherOption", "anyOption":
            self = .option
        case Self.leftOption.rawValue, "left_option", "left-option":
            self = .leftOption
        case Self.rightOption.rawValue, "right_option", "right-option":
            self = .rightOption
        case Self.leftCommand.rawValue, "left_command", "left-command":
            self = .leftCommand
        case Self.rightCommand.rawValue, "right_command", "right-command":
            self = .rightCommand
        case Self.leftControl.rawValue, "left_control", "left-control":
            self = .leftControl
        case Self.rightControl.rawValue, "right_control", "right-control":
            self = .rightControl
        case Self.function.rawValue, "fn":
            self = .function
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported trigger key: \(value)"
            )
        }
    }
}

/// Versioned user preference for the voice recording trigger.
struct HotkeyProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let defaultProfile = HotkeyProfile(trigger: .option, behavior: .toggle)

    let schemaVersion: Int
    let trigger: TriggerKey
    let behavior: TriggerBehavior
    /// Optional physical key code for a fully custom shortcut. When nil, the
    /// selected modifier key (Option/Command/Control/Fn) is used.
    let keyCode: UInt16?

    init(
        trigger: TriggerKey,
        behavior: TriggerBehavior,
        keyCode: UInt16? = nil,
        schemaVersion: Int = HotkeyProfile.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.trigger = trigger
        self.behavior = behavior
        self.keyCode = keyCode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case version
        case trigger
        case triggerKey
        case behavior
        case keyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentSchemaVersion
        trigger = try container.decodeIfPresent(TriggerKey.self, forKey: .trigger)
            ?? container.decode(TriggerKey.self, forKey: .triggerKey)
        behavior = try container.decodeIfPresent(TriggerBehavior.self, forKey: .behavior)
            ?? .toggle
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(behavior, forKey: .behavior)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
    }
}

/// Small persistence boundary so tests and previews can inject an isolated
/// UserDefaults suite without touching the user's real NexVoice preferences.
struct HotkeyProfileStore {
    static let profileKey = "nexvoice.hotkey.profile"

    private enum LegacyKey {
        static let triggers = [
            "nexvoice.hotkey.trigger",
            "nexvoice.native.hotkeyTrigger",
        ]
        static let behaviors = [
            "nexvoice.hotkey.behavior",
            "nexvoice.native.hotkeyBehavior",
        ]
    }

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Loads the current profile, migrates legacy scalar keys when found, and
    /// safely falls back to the product default for missing/corrupt data.
    func load() -> HotkeyProfile {
        if let data = defaults.data(forKey: Self.profileKey),
           let profile = try? decoder.decode(HotkeyProfile.self, from: data),
           profile.schemaVersion <= HotkeyProfile.currentSchemaVersion {
            return profile
        }

        if let legacy = loadLegacyProfile() {
            try? save(legacy)
            return legacy
        }

        return .defaultProfile
    }

    func save(_ profile: HotkeyProfile) throws {
        let current = HotkeyProfile(
            trigger: profile.trigger,
            behavior: profile.behavior,
            keyCode: profile.keyCode
        )
        defaults.set(try encoder.encode(current), forKey: Self.profileKey)
    }

    private func loadLegacyProfile() -> HotkeyProfile? {
        guard let triggerString = firstString(forKeys: LegacyKey.triggers),
              let trigger = decode(TriggerKey.self, from: triggerString)
        else {
            return nil
        }

        let behavior = firstString(forKeys: LegacyKey.behaviors)
            .flatMap { decode(TriggerBehavior.self, from: $0) }
            ?? .toggle
        return HotkeyProfile(trigger: trigger, behavior: behavior)
    }

    private func firstString(forKeys keys: [String]) -> String? {
        keys.lazy.compactMap { defaults.string(forKey: $0) }.first
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from value: String) -> Value? {
        try? decoder.decode(type, from: Data("\"\(value)\"".utf8))
    }
}
