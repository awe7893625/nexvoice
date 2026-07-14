import Foundation

enum TranscriptLanguage {
    /// Whisper's `zh` decoder can emit Simplified Chinese even when the user
    /// speaks Taiwan Mandarin. ICU's built-in transform keeps Latin text and
    /// punctuation intact while normalizing Han characters to Traditional.
    static func traditionalChinese(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }
}
