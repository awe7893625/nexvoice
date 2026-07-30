import AppKit
import Foundation

enum HotkeyOwner: String, Codable, Sendable {
    case legacy
    case native
    case typeless
    case unknown
}

enum LegacyBridgeResult: Equatable, Sendable {
    case acknowledged
    case hammerspoonNotRunning
    case timeout
    case protocolMismatch
    case ioFailure(String)

    var succeeded: Bool {
        switch self {
        case .acknowledged, .hammerspoonNotRunning: true
        case .timeout, .protocolMismatch, .ioFailure: false
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .acknowledged: "acknowledged"
        case .hammerspoonNotRunning: "hammerspoon-not-running"
        case .timeout: "timeout"
        case .protocolMismatch: "protocol-mismatch"
        case .ioFailure(let detail): "io-failure:\(detail)"
        }
    }
}

private struct HotkeyOwnerRecord: Codable {
    let schemaVersion: Int
    let owner: HotkeyOwner
    let processID: Int32
    let bundlePath: String
    let transitionID: UUID
    let updatedAt: String
}

enum LegacyBridge {
    // 0.5s is a genuinely tight budget for fork+exec of the `hs` CLI binary
    // plus a full Hammerspoon IPC round-trip; under any concurrent load on
    // Hammerspoon's single IPC channel (e.g. another `hs -c` caller) it can
    // miss the deadline even though Hammerspoon itself is healthy. A missed
    // handoff silently leaves the App ceded to the legacy trigger with no
    // user-visible error, so this errs generous rather than snappy.
    private static let bridgeTimeout: TimeInterval = 2.0
    private static let transitionMutex = AsyncMutex()

    /// Change the bare-modifier owner as a transaction. Hammerspoon must ACK
    /// before the owner marker is committed, so the marker cannot claim native
    /// ownership while the legacy trigger is still live.
    @MainActor
    static func transition(to owner: HotkeyOwner) async -> LegacyBridgeResult {
        await transitionMutex.lock()
        let result = await performTransition(to: owner)
        await transitionMutex.unlock()
        return result
    }

    @MainActor
    private static func performTransition(to owner: HotkeyOwner) async -> LegacyBridgeResult {
        let previousOwner = loadOwner() ?? .legacy
        let hammerspoonRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "org.hammerspoon.Hammerspoon"
        }

        let bridgeResult: LegacyBridgeResult
        if hammerspoonRunning {
            bridgeResult = await invokeHammerspoon(
                legacyEnabled: owner == .legacy,
                timeout: bridgeTimeout
            )
            guard bridgeResult.succeeded else { return bridgeResult }
        } else {
            bridgeResult = .hammerspoonNotRunning
        }

        guard persistOwner(owner) else {
            // Best-effort rollback of the runtime when the durable commit fails.
            if hammerspoonRunning {
                _ = await invokeHammerspoon(
                    legacyEnabled: previousOwner == .legacy,
                    timeout: bridgeTimeout
                )
            }
            return .ioFailure("owner-record")
        }
        return bridgeResult
    }

    static func loadOwner() -> HotkeyOwner? {
        let recordURL = cacheDirectory.appendingPathComponent("hotkey-owner.json")
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(HotkeyOwnerRecord.self, from: data)
        else { return nil }
        return record.owner
    }

    private static func invokeHammerspoon(
        legacyEnabled: Bool,
        timeout: TimeInterval
    ) async -> LegacyBridgeResult {
        await Task.detached(priority: .userInitiated) {
            let candidates = [
                ProcessInfo.processInfo.environment["NEXVOICE_HS_PATH"],
                "/opt/homebrew/bin/hs",
                "/usr/local/bin/hs",
            ].compactMap { $0 }
            guard let executable = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else {
                return .ioFailure("hs-unavailable")
            }

            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            let target = legacyEnabled ? "true" : "false"
            process.arguments = [
                "-c",
                // `target` must be a Lua boolean. Passing "false" as a string
                // is truthy in Lua and silently re-enables the legacy trigger.
                "local target=\(target); return tostring(_G.NexVoice.setLegacyTriggerEnabled(target) == target)",
            ]
            process.standardOutput = output
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return .ioFailure("launch")
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !process.isRunning else {
                process.terminate()
                return .timeout
            }

            let response = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init)
            guard process.terminationStatus == 0, response == "true" else {
                return .protocolMismatch
            }
            return .acknowledged
        }.value
    }

    private static func persistOwner(_ owner: HotkeyOwner) -> Bool {
        let marker = cacheDirectory.appendingPathComponent("native-owner")
        let recordURL = cacheDirectory.appendingPathComponent("hotkey-owner.json")
        let record = HotkeyOwnerRecord(
            schemaVersion: 1,
            owner: owner,
            processID: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundleURL.path,
            transitionID: UUID(),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: cacheDirectory.path
            )

            let data = try JSONEncoder().encode(record)
            try data.write(to: recordURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recordURL.path
            )

            if owner == .legacy {
                if FileManager.default.fileExists(atPath: marker.path) {
                    try FileManager.default.removeItem(at: marker)
                }
            } else {
                try Data("\(owner.rawValue)\n".utf8).write(to: marker, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: marker.path
                )
            }
            return true
        } catch {
            return false
        }
    }

    private static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/nexvoice", isDirectory: true)
    }
}

actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
