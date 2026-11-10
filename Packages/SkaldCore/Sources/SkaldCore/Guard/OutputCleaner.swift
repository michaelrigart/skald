import Foundation

public enum OutputCleaner {
    private static let quotePairs: [(open: Character, close: Character)] = [("\"", "\""), ("“", "”"), ("«", "»")]
    private static let preamble = try! NSRegularExpression(
        pattern: #"^(?:corrected text|here is the corrected text|corrected)\s*:"#,
        options: .caseInsensitive
    )

    public static func clean(_ output: String, input: String) -> String {
        var text = removingThinkBlock(trimmed(output))
        while true {
            let next = removingWrappingQuotes(removingPreamble(removingCodeFence(text, input: input), input: input), input: input)
            if next == text { return text }
            text = next
        }
    }

    /// The output with the input's leading and trailing whitespace, which `clean` trims away: a chunk's
    /// trailing space separates it from the next chunk, and the model never answers for it.
    public static func keepingEdges(of input: String, _ cleaned: String) -> String {
        let (lead, _, trail) = edges(of: input)
        return lead + cleaned + trail
    }

    /// The text without its leading and trailing whitespace, and that whitespace.
    public static func edges(of text: String) -> (lead: String, body: String, trail: String) {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
        else { return (text, "", "") }
        func string(_ slice: ArraySlice<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: slice)
            return String(view)
        }
        return (string(scalars[..<first]), string(scalars[first...last]), string(scalars[(last + 1)...]))
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingThinkBlock(_ text: String) -> String {
        guard text.hasPrefix("<think>"), let end = text.range(of: "</think>") else { return text }
        return trimmed(String(text[end.upperBound...]))
    }

    private static func removingCodeFence(_ text: String, input: String) -> String {
        guard text.count >= 6, text.hasPrefix("```"), text.hasSuffix("```"), !input.contains("```") else { return text }
        var body = Substring(text.dropFirst(3).dropLast(3))
        if let newline = body.firstIndex(of: "\n"), body[..<newline].allSatisfy({ $0.isLetter || $0.isNumber || "_+-".contains($0) }) {
            body = body[body.index(after: newline)...]
        }
        return trimmed(String(body))
    }

    private static func removingPreamble(_ text: String, input: String) -> String {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let source = trimmed(input)
        guard preamble.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) == nil,
              let match = preamble.firstMatch(in: text, range: whole) else { return text }
        return trimmed((text as NSString).substring(from: match.range.upperBound))
    }

    private static func removingWrappingQuotes(_ text: String, input: String) -> String {
        let source = trimmed(input)
        for (open, close) in quotePairs {
            guard text.count >= 2, text.first == open, text.last == close, source.first != open else { continue }
            let inner = text.dropFirst().dropLast()
            if inner.contains(open) || inner.contains(close) { return text }
            return trimmed(String(inner))
        }
        return text
    }
}
