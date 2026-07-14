import AppKit
import ApplicationServices
import Foundation

enum InstructionKind: Equatable {
    case edit
    case ask
}

enum SelectionService {
    /// Best-effort selected text from the focused UI element (AX).
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
              let element = focused
        else { return nil }

        let ax = element as! AXUIElement
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            ax,
            kAXSelectedTextAttribute as CFString,
            &selected
        ) == .success,
           let text = selected as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return text
        }

        // Fallback: some fields only expose full value with a selection range.
        var value: CFTypeRef?
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXValueAttribute as CFString, &value) == .success,
              let full = value as? String,
              AXUIElementCopyAttributeValue(
                  ax,
                  kAXSelectedTextRangeAttribute as CFString,
                  &range
              ) == .success
        else { return nil }

        var cfRange = CFRange()
        // AXValueGetValue needs AXValueRef
        if CFGetTypeID(range) == AXValueGetTypeID(),
           AXValueGetValue(range as! AXValue, .cfRange, &cfRange),
           cfRange.length > 0,
           cfRange.location >= 0
        {
            let ns = full as NSString
            let location = min(cfRange.location, ns.length)
            let length = min(cfRange.length, ns.length - location)
            guard length > 0 else { return nil }
            let slice = ns.substring(with: NSRange(location: location, length: length))
            let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : slice
        }
        return nil
    }

    static func classifyInstruction(_ text: String) -> InstructionKind {
        let lower = text.lowercased()
        let rewriteHints = ["改成", "改寫", "縮短", "加長", "正式", "口語", "make it", "shorten", "rewrite"]
        if rewriteHints.contains(where: { lower.contains($0) }) {
            return .edit
        }
        let askHints = [
            "總結", "摘要", "總括", "重點", "解釋", "說明", "什麼意思", "是什麼",
            "翻譯", "譯成", "翻成", "translate", "summar", "explain", "what does"
        ]
        if askHints.contains(where: { lower.contains($0) }) {
            return .ask
        }
        return .edit
    }
}
