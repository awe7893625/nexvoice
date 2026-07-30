import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// Deep-link into macOS System Settings privacy panes.
@MainActor
enum SystemSettings {
    enum Pane {
        case microphone
        case accessibility
        case privacyRoot
    }

    /// Open Settings and land on the right privacy list when possible.
    @discardableResult
    static func open(_ pane: Pane) -> Bool {
        // 1) Preferred x-callback style URLs (macOS 13–26)
        for urlString in urls(for: pane) {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return true
            }
        }

        // Last resort: just open System Settings. Avoid Apple Events entirely;
        // paste uses Accessibility/CGEvent and must not cause Automation prompts.
        return NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app")
        )
    }

    static func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                try? await Task.sleep(for: .milliseconds(250))
                open(.microphone)
            }
            return granted
        case .denied, .restricted:
            NSApp.activate(ignoringOtherApps: true)
            open(.microphone)
            return false
        @unknown default:
            open(.microphone)
            return false
        }
    }

    /// Prompt + open Accessibility list. User must flip the NexVoice switch ON.
    @discardableResult
    static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        NSApp.activate(ignoringOtherApps: true)

        // Register this process with TCC so a row appears.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Always open the list so user can enable the switch (prompt alone is easy to miss).
        open(.accessibility)

        // Helpful dialog on top of Settings (Settings sometimes steals focus).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let alert = NSAlert()
            alert.messageText = "請在系統設定打開 NexVoice 開關"
            alert.informativeText = """
            已開啟「隱私權與安全性 → 輔助使用」。

            請在列表找到 NexVoice（或 uk.blankspaces.nexvoice），把右側開關打開。
            打開後回到此 App 按「重新檢查」。
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "我知道了")
            alert.runModal()
        }

        return AXIsProcessTrusted()
    }

    private static func urls(for pane: Pane) -> [String] {
        switch pane {
        case .microphone:
            return [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.Privacy_Microphone",
            ]
        case .accessibility:
            return [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.Privacy_Accessibility",
            ]
        case .privacyRoot:
            return [
                "x-apple.systempreferences:com.apple.preference.security?Privacy",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            ]
        }
    }

}
