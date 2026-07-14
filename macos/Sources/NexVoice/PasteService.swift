import AppKit
import ApplicationServices
import Foundation

enum PasteOutcome: Equatable {
    case pasted
    case clipboardOnly
}

enum PasteService {
    @MainActor
    static func insertOnce(_ text: String, target: NSRunningApplication?) async -> PasteOutcome {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        guard AXIsProcessTrusted(), let target else { return .clipboardOnly }
        _ = target.activate(options: [])
        do {
            try await Task.sleep(for: .milliseconds(180))
        } catch {
            return .clipboardOnly
        }
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        else { return .clipboardOnly }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return .clipboardOnly }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .pasted
    }

    static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
