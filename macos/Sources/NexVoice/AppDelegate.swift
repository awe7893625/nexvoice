import AppKit
import SwiftUI

extension Notification.Name {
    static let nexVoiceShowUI = Notification.Name("uk.blankspaces.nexvoice.showUI")
}

/// Lifecycle: one main window, optional one onboarding — never spam.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated static let distributedActivate = Notification.Name("uk.blankspaces.nexvoice.distributed.activate")
    nonisolated static let distributedPrepareForUpdate = Notification.Name("uk.blankspaces.nexvoice.prepareForUpdate")
    static var shutdownHandler: (() async -> Bool)?

    private static var lastFocusAt: TimeInterval = 0
    private var terminationInProgress = false
    private var shutdownComplete = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedActivate),
            name: Self.distributedActivate,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handlePrepareForUpdate),
            name: Self.distributedPrepareForUpdate,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Single main window: open once if missing, then focus.
            Self.focusExistingUI(openMainIfNeeded: true, openOnboardingIfNeeded: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.focusExistingUI(openMainIfNeeded: true, openOnboardingIfNeeded: false)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownComplete { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }
        guard let shutdownHandler = Self.shutdownHandler else { return .terminateNow }
        terminationInProgress = true
        Task { @MainActor in
            let safeToTerminate = await shutdownHandler()
            self.shutdownComplete = safeToTerminate
            self.terminationInProgress = safeToTerminate
            sender.reply(toApplicationShouldTerminate: safeToTerminate)
        }
        return .terminateLater
    }

    @objc private func handleDistributedActivate(_ note: Notification) {
        Self.focusExistingUI(openMainIfNeeded: true, openOnboardingIfNeeded: false)
    }

    @objc private func handlePrepareForUpdate(_ note: Notification) {
        guard Self.consumeValidUpdateRequest(note.userInfo),
              !terminationInProgress,
              let shutdownHandler = Self.shutdownHandler
        else { return }
        terminationInProgress = true
        Task { @MainActor in
            let safeToTerminate = await shutdownHandler()
            self.shutdownComplete = safeToTerminate
            self.terminationInProgress = false
            if safeToTerminate { NSApp.terminate(nil) }
        }
    }

    nonisolated static func pingRunningInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            distributedActivate,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    nonisolated static func requestGracefulShutdown() {
        let nonce = UUID().uuidString
        guard persistUpdateNonce(nonce) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            distributedPrepareForUpdate,
            object: nil,
            userInfo: ["nonce": nonce],
            deliverImmediately: true
        )
    }

    private nonisolated static func persistUpdateNonce(_ nonce: String) -> Bool {
        let url = updateNonceURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(nonce.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    private static func consumeValidUpdateRequest(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let requested = userInfo?["nonce"] as? String,
              let stored = try? String(contentsOf: updateNonceURL, encoding: .utf8),
              stored == requested
        else { return false }
        try? FileManager.default.removeItem(at: updateNonceURL)
        return true
    }

    private nonisolated static var updateNonceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/nexvoice", isDirectory: true)
            .appendingPathComponent("update-request")
    }

    static func mainWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            let title = window.title
            if title.contains("設定引導") { return false }
            if window.level != .normal { return false }
            return window.styleMask.contains(.titled) && window.styleMask.contains(.resizable)
        }
    }

    static func onboardingWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.title.contains("設定引導") }
    }

    static func collapseDuplicateWindows() {
        let mains = mainWindows()
        guard mains.count > 1 else { return }
        for window in mains.dropFirst() {
            window.close()
        }
        let boards = onboardingWindows()
        guard boards.count > 1 else { return }
        for window in boards.dropFirst() {
            window.close()
        }
    }

    static func focusExistingUI(openMainIfNeeded: Bool, openOnboardingIfNeeded: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastFocusAt < 0.8 {
            collapseDuplicateWindows()
            return
        }
        lastFocusAt = now

        collapseDuplicateWindows()

        if let main = mainWindows().first {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else if openMainIfNeeded {
            NotificationCenter.default.post(
                name: .nexVoiceShowUI,
                object: nil,
                userInfo: ["openMain": true]
            )
        }

        if openOnboardingIfNeeded {
            let done = UserDefaults.standard.bool(forKey: "nexvoice.native.onboardingCompleted")
            if !done, onboardingWindows().isEmpty {
                NotificationCenter.default.post(
                    name: .nexVoiceShowUI,
                    object: nil,
                    userInfo: ["openOnboarding": true]
                )
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Sole SwiftUI openWindow gate.
struct WindowActivator: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .nexVoiceShowUI)) { note in
                let info = note.userInfo ?? [:]
                let openMain = info["openMain"] as? Bool ?? false
                let openOnboarding = info["openOnboarding"] as? Bool ?? false

                if openMain, AppDelegate.mainWindows().isEmpty {
                    openWindow(id: "dashboard")
                }
                if openOnboarding, AppDelegate.onboardingWindows().isEmpty {
                    openWindow(id: "onboarding")
                } else if model.showOnboarding, AppDelegate.onboardingWindows().isEmpty {
                    openWindow(id: "onboarding")
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    AppDelegate.collapseDuplicateWindows()
                    if let main = AppDelegate.mainWindows().first {
                        main.makeKeyAndOrderFront(nil)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
