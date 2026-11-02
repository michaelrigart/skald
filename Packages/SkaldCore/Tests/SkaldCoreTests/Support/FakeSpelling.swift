import Foundation
@testable import SkaldCore

/// Flags every whole-word occurrence of a listed misspelling, one edit per occurrence, as the system checker
/// does. It ignores `neverTouch` on purpose, so tests see the pipeline's guard drop those flags.
actor FakeSpelling: SpellingChecking {
    struct Call: Equatable, Sendable {
        let text: String
        let language: Language
        let neverTouch: Set<String>
    }

    private let misspellings: [String: String]
    private(set) var calls: [Call] = []

    init(_ misspellings: [String: String]) {
        self.misspellings = misspellings
    }

    func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) -> [Edit] {
        calls.append(Call(text: p.text, language: language, neverTouch: neverTouch))
        let text = p.text as NSString
        return Tokenizer.tokens(in: p.text).flatMap { token -> [Edit] in
            guard let suggestion = misspellings[token.text] else { return [] }
            let revised = text.replacingCharacters(in: NSRange(location: token.range.location, length: token.range.length), with: suggestion)
            return TextDiff.edits(from: p.text, to: revised)
        }
    }

    var texts: [String] { calls.map(\.text) }
}
