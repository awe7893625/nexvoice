import Foundation

enum HotkeyGesturePhase: Equatable, Sendable {
    case pressed
    case released
}

enum HotkeyGestureAction: Equatable, Sendable {
    case startRecording
    case finishRecording
    case cancelRecording
    case none
}

/// Pure reducer for physical modifier gestures. AppKit event translation lives
/// in VoiceRuntimeController; this type is deterministic and race-testable.
struct HotkeyGestureEngine: Sendable {
    private(set) var profile: HotkeyProfile
    private(set) var triggerIsDown = false

    init(profile: HotkeyProfile = .defaultProfile) {
        self.profile = profile
    }

    mutating func setProfile(_ profile: HotkeyProfile) {
        self.profile = profile
        triggerIsDown = false
    }

    mutating func reset() {
        triggerIsDown = false
    }

    mutating func handle(
        _ phase: HotkeyGesturePhase,
        isRecording: Bool,
        canStart: Bool
    ) -> HotkeyGestureAction {
        switch phase {
        case .pressed:
            guard !triggerIsDown else { return .none }
            triggerIsDown = true
            switch profile.behavior {
            case .toggle:
                // A bare-modifier toggle commits on release so Option/Command
                // chords do not start recording before the other key arrives.
                return .none
            case .pushToTalk:
                return canStart ? .startRecording : .none
            }

        case .released:
            guard triggerIsDown else { return .none }
            triggerIsDown = false
            switch profile.behavior {
            case .toggle:
                if isRecording { return .finishRecording }
                return canStart ? .startRecording : .none
            case .pushToTalk:
                return isRecording ? .finishRecording : .none
            }
        }
    }

    mutating func cancelForChord(isRecording: Bool) -> HotkeyGestureAction {
        guard triggerIsDown else { return .none }
        triggerIsDown = false
        guard profile.behavior == .pushToTalk, isRecording else { return .none }
        return .cancelRecording
    }
}
