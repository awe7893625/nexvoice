import Foundation

enum STTRoute: String, Equatable {
    case localMLX = "Local MLX"
    case groqWhisper = "Groq Whisper"
    case unavailable = "無可用路由"
}

/// Hard caps for a single recording session (security residual: unbounded disk use).
enum RecordingLimits {
    /// Minimum useful utterance before pipeline runs.
    static let minDurationSeconds: TimeInterval = 0.35
    /// Maximum continuous recording; auto-finishes into the normal pipeline.
    /// Midpoint of the 2–5 minute hardening range from the security audit.
    static let maxDurationSeconds: TimeInterval = 180
}

struct RuntimeSnapshot: Equatable {
    let localHealthy: Bool
    let overloaded: Bool
    let localEnabled: Bool
    let groqConfigured: Bool
    let privacyMode: Bool
}

struct RoutingPolicy {
    func choose(_ snapshot: RuntimeSnapshot) -> STTRoute {
        if snapshot.privacyMode {
            return snapshot.localEnabled && snapshot.localHealthy ? .localMLX : .unavailable
        }
        if snapshot.localEnabled && snapshot.localHealthy {
            // Under the zero-cost/default policy there is no authorized cloud
            // route, so a busy local service is still preferable to failure.
            if !snapshot.overloaded || !snapshot.groqConfigured {
                return .localMLX
            }
        }
        return snapshot.groqConfigured ? .groqWhisper : .unavailable
    }
}

struct SessionPasteGate {
    private(set) var currentSession: UUID?
    private var didPaste = false

    mutating func begin(session: UUID) {
        currentSession = session
        didPaste = false
    }

    mutating func cancel(session: UUID) {
        guard currentSession == session else { return }
        currentSession = nil
        didPaste = false
    }

    mutating func claimPaste(session: UUID) -> Bool {
        guard currentSession == session, !didPaste else { return false }
        didPaste = true
        return true
    }
}
