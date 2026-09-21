import Foundation

/// Normalizes text crossing the model boundary in either direction.
public enum ReplySanitizer {
    /// A single-line, bounded question, or nil when nothing meaningful remains.
    public static func prompt(_ text: String, limit: Int) -> String? {
        let flattened = collapsingWhitespace(removingControlCharacters(text))
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(max(1, limit)))
    }

    /// Text that reads naturally aloud: no markdown, emoji, or line structure,
    /// capped at a sentence boundary when possible. Nil when nothing speakable remains.
    public static func spoken(_ text: String, limit: Int) -> String? {
        var lines: [String] = []
        for line in removingControlCharacters(text, keepingNewlines: true).split(whereSeparator: \.isNewline) {
            lines.append(strippingLineMarkup(String(line)))
        }
        let inline = strippingInlineMarkup(lines.joined(separator: " "))
        let speakable = collapsingWhitespace(removingEmoji(inline))
            .replacing(/\s+([.,!?;:…])/) { String($0.output.1) }
        guard speakable.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return capped(speakable, limit: max(1, limit))
    }

    private static func removingControlCharacters(_ text: String, keepingNewlines: Bool = false) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if keepingNewlines, scalar == "\n" {
                scalars.append(scalar)
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            case .format where scalar.value != 0x200C && scalar.value != 0x200D:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func strippingLineMarkup(_ line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespaces)
        result = result.replacing(/^#{1,6}\s+/, with: "")
        result = result.replacing(/^>\s*/, with: "")
        result = result.replacing(/^(?:[-*+•]|\d{1,3}[.)])\s+/, with: "")
        return result
    }

    private static func strippingInlineMarkup(_ text: String) -> String {
        var result = text.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
        for marker in ["**", "__", "`", "*"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result
    }

    private static func removingEmoji(_ text: String) -> String {
        String(text.filter { !isEmoji($0) })
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || scalar.value == 0xFE0F
                || scalar.value == 0x20E3
                || (scalar.properties.isEmoji && scalar.value >= 0x2000)
        }
    }

    private static func capped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let window = String(text.prefix(limit))
        let terminators: Set<Character> = [".", "!", "?", "…"]
        if let end = window.lastIndex(where: { terminators.contains($0) }),
           window.distance(from: window.startIndex, to: end) >= limit / 2 {
            return String(window[...end])
        }
        let words = window.split(separator: " ", omittingEmptySubsequences: true)
        let truncated = words.count > 1 ? words.dropLast().joined(separator: " ") : window
        return truncated.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}
