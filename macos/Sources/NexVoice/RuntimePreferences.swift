import Foundation

struct RuntimePreferences: Equatable {
    var privacyMode: Bool
    var cleanupEnabled: Bool
    var localEnabled: Bool
    var localHealthy: Bool
    var overloaded: Bool
    var groqConfigured: Bool
    var cloudSTTAllowed: Bool
    var cloudTextAllowed: Bool
    var cloudTextConfigured: Bool

    var allowsCloudSTT: Bool {
        !privacyMode && cloudSTTAllowed && groqConfigured
    }

    var allowsCloudText: Bool {
        !privacyMode && cloudTextAllowed && cloudTextConfigured
    }

    var snapshot: RuntimeSnapshot {
        RuntimeSnapshot(
            localHealthy: localHealthy,
            overloaded: overloaded,
            localEnabled: localEnabled,
            groqConfigured: allowsCloudSTT,
            privacyMode: privacyMode
        )
    }
}
