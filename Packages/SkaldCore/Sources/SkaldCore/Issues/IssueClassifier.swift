import Foundation

/// Decides an edit's kind from the edit itself, never from the model. The first rule that matches wins.
public enum IssueClassifier {
    /// `facts` are the oracle's for the edit's words, as the guard gets them; rule 4 reads `misspelled` and the guard's
    /// function-word test, rule 6 reads `lemmas`.
    public static func kind(of edit: Edit, in paragraph: String, language: Language, source: IssueSource, facts: WordFacts) -> IssueKind {
        let original = EditGuard.wordTokens(in: edit.original)
        let replacement = EditGuard.wordTokens(in: edit.replacement)

        if original == replacement { return .punctuation }
        if original.map({ $0.lowercased() }) == replacement.map({ $0.lowercased() }) { return .capital }
        if original.map(fold) == replacement.map(fold) { return .accent }
        if source == .spelling || original.contains(where: { isRejected($0, language, facts) }) { return .spelling }
        if isRepeatedWord(edit, original, replacement, in: paragraph) { return .repeatedWord }
        if language == .nl, original.count == 1, replacement.count == 1, isVerbForm(original[0], replacement[0], facts) { return .verbForm }
        return .grammar
    }

    private static func isRejected(_ word: String, _ language: Language, _ facts: WordFacts) -> Bool {
        let word = word.lowercased()
        return facts.misspelled.contains(word) && !EditGuard.isFunctionWord(word, language, facts)
    }

    private static func fold(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func isRepeatedWord(_ edit: Edit, _ original: [String], _ replacement: [String], in paragraph: String) -> Bool {
        guard original.count == 1, replacement.isEmpty else { return false }
        let tokens = Tokenizer.tokens(in: paragraph)
        let before = tokens[..<edit.tokenSpan.lowerBound].last { EditGuard.isWord($0.text) }
        let after = tokens[edit.tokenSpan.upperBound...].first { EditGuard.isWord($0.text) }
        return [before, after].contains { $0?.text.caseInsensitiveCompare(original[0]) == .orderedSame }
    }

    private static func isVerbForm(_ from: String, _ to: String, _ facts: WordFacts) -> Bool {
        func stem(_ word: String) -> String? {
            let word = word.lowercased()
            guard let suffix = ["dt", "d", "t"].first(where: word.hasSuffix) else { return nil }
            return String(word.dropLast(suffix.count))
        }
        guard let a = stem(from), let b = stem(to), a == b, a.count >= 2 else { return false }
        if let lemma = facts.lemmas[from.lowercased()], let other = facts.lemmas[to.lowercased()] { return lemma == other }
        return true
    }
}
