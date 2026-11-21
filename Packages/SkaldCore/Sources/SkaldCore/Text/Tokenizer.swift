import Foundation

public struct Token: Equatable, Sendable {
    public let text: String
    public let range: TextRange
}

public enum Tokenizer {
    private static let regex = try! NSRegularExpression(pattern: #"\w+|[^\w\s]"#)

    public static func tokens(in text: String) -> [Token] {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { Token(text: ns.substring(with: $0.range), range: TextRange($0.range)) }
    }
}
