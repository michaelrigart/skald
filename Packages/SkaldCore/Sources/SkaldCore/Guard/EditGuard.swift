import Foundation

public enum DropReason: Equatable, Sendable {
    case neverTouch, nameNumberURLOrCode, borrowedWord, replacement, tenseChange, addedFormality, noSuggestion, compoundSplit, spellingVariant
}

public enum GuardVerdict: Equatable, Sendable {
    case keep, drop(DropReason), undecided
}

public enum DiscardReason: Equatable, Sendable {
    case languageChanged, tooManyChanges, empty
}

public enum WholeResult: Equatable, Sendable {
    case accepted, discarded(DiscardReason)
}

public struct EditGuard: Sendable {
    private let neverTouch: Set<String>
    private let maxChangeShare: Double

    public init(neverTouch: Set<String>, maxChangeShare: Double = 0.4) {
        self.neverTouch = Set(neverTouch.map { $0.lowercased() })
        self.maxChangeShare = maxChangeShare
    }

    public func judgeWhole(original: String, revised: String, language: Language, revisedLanguage: Language?) -> WholeResult {
        if revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .discarded(.empty) }
        if let revisedLanguage, revisedLanguage != language { return .discarded(.languageChanged) }
        func wordCount<S: StringProtocol>(_ text: S) -> Int { text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count }
        let source = original as NSString
        let changed = TextDiff.edits(from: original, to: revised).reduce(0) {
            let splice = source.substring(with: NSRange(location: $1.spliceRange.location, length: $1.spliceRange.length))
            return $0 + max(wordCount(splice), wordCount($1.spliceText))
        }
        let total = wordCount(original)
        if changed > 2, total > 0, Double(changed) / Double(total) > maxChangeShare { return .discarded(.tooManyChanges) }
        return .accepted
    }

    public func resolve(
        _ edits: [Edit],
        in paragraph: String,
        language: Language,
        source: IssueSource,
        oracle: any WordOracle,
        confirmer: (any EditConfirming)?
    ) async -> [Edit] {
        guard !edits.isEmpty else { return [] }
        let facts = await oracle.facts(for: Self.words(in: edits), language: language)
        let verdicts = edits.map { verdict(for: $0, in: paragraph, language: language, source: source, facts: facts) }
        let rewrites = source == .model ? zip(edits, verdicts).filter { Self.isRewrite($0.1) }.map(\.0.tokenSpan) : []
        var kept: [Edit] = []
        for (edit, verdict) in zip(edits, verdicts) {
            switch verdict {
            case .keep where Self.isAbsorbed(edit, by: rewrites, language, facts):
                break
            case .keep:
                kept.append(edit)
            case .drop:
                break
            case .undecided:
                if await confirmer?.confirm(edit, in: paragraph, language: language) == true { kept.append(edit) }
            }
        }
        return kept
    }

    private static func isRewrite(_ verdict: GuardVerdict) -> Bool {
        [.drop(.replacement), .drop(.borrowedWord), .drop(.tenseChange)].contains(verdict)
    }

    private static func areNeighbours(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        b.lowerBound - a.upperBound <= 1 && a.lowerBound - b.upperBound <= 1
    }

    private static func isAbsorbed(_ edit: Edit, by rewrites: [Range<Int>], _ language: Language, _ facts: WordFacts) -> Bool {
        rewrites.contains { areNeighbours($0, edit.tokenSpan) } && !isCapitalisationOnly(edit) && swapsOnlyFunctionWords(edit, language, facts)
    }

    public func verdict(for edit: Edit, in paragraph: String, language: Language, source: IssueSource, facts: WordFacts) -> GuardVerdict {
        let tokens = Tokenizer.tokens(in: paragraph)
        let original = Self.words(in: edit.original)
        let replacement = Self.words(in: edit.replacement)
        let isFunctionWord = { (word: String) in Self.isFunctionWord(word, language, facts) }

        if touchesNeverTouch(edit, in: paragraph, replacement) { return .drop(.neverTouch) }
        if Self.isNumberURLCodeOrName(edit, in: paragraph, tokens: tokens) { return .drop(.nameNumberURLOrCode) }
        if source == .spelling && edit.replacement.isEmpty { return .drop(.noSuggestion) }
        if original.isEmpty && replacement.isEmpty { return Self.punctuationVerdict(edit, tokens) }
        if Self.isCapitalisationOnly(edit) { return Self.capitalisationVerdict(edit, tokens, language) }
        if source == .spelling && Self.isCompoundSplit(edit, replacement, isFunctionWord) { return .drop(.compoundSplit) }
        if language != .en,
           let verdict = Self.borrowedWordVerdict(original.filter { !isFunctionWord($0) }, replacement.filter { !isFunctionWord($0) }, facts) {
            return verdict
        }
        if original.contains(where: { facts.misspelled.contains($0) && !isFunctionWord($0) }) { return .keep }
        if language == .en, original.count == 1, replacement.count == 1, Self.isSpellingVariant(original[0], replacement[0], facts) {
            return .drop(.spellingVariant)
        }
        if Self.swapsOnlyFunctionWords(edit, language, facts) { return .keep }
        let auxiliary = Self.auxiliaryContext(edit, tokens, language)
        return Self.contentVerdict(original, replacement, facts, language, isFunctionWord, auxiliary)
    }

    static func words(in text: String) -> [String] {
        Tokenizer.tokens(in: text).map(\.text).filter(isWord).map { $0.lowercased() }
    }

    static func words(in edits: [Edit]) -> Set<String> {
        Set(edits.flatMap { words(in: $0.original) + words(in: $0.replacement) })
    }

    private static func isFunctionWord(_ word: String, _ language: Language, _ facts: WordFacts) -> Bool {
        facts.functionWords.contains(word) || FunctionWords.contains(word, language)
    }

    private static func swapsOnlyFunctionWords(_ edit: Edit, _ language: Language, _ facts: WordFacts) -> Bool {
        let words = words(in: edit.original) + words(in: edit.replacement)
        return !words.isEmpty && !words.contains { FunctionWords.isPreposition($0, language) }
            && words.allSatisfy { isFunctionWord($0, language, facts) }
    }

    public func touchesNeverTouch(_ edit: Edit, in paragraph: String) -> Bool {
        touchesNeverTouch(edit, in: paragraph, Self.words(in: edit.replacement))
    }

    private func touchesNeverTouch(_ edit: Edit, in paragraph: String, _ replacement: [String]) -> Bool {
        if !neverTouch.isDisjoint(with: replacement + [edit.replacement.lowercased()]) { return true }
        let text = paragraph as NSString
        func isWordCharacter(_ position: Int) -> Bool {
            guard position >= 0, position < text.length else { return false }
            return Unicode.Scalar(text.character(at: position)).map { CharacterSet.alphanumerics.contains($0) || $0 == "_" } ?? false
        }
        func overlapsEdit(_ found: NSRange) -> Bool {
            if edit.range.length == 0 { return found.location < edit.range.location && edit.range.location < found.location + found.length }
            return found.location < edit.range.end && edit.range.location < found.location + found.length
        }
        for entry in neverTouch where !entry.isEmpty {
            var from = 0
            while from < text.length {
                let found = text.range(of: entry, options: .caseInsensitive, range: NSRange(location: from, length: text.length - from))
                if found.location == NSNotFound { break }
                if !isWordCharacter(found.location - 1), !isWordCharacter(found.location + found.length), overlapsEdit(found) { return true }
                from = found.location + 1
            }
        }
        return false
    }

    private static func isWord(_ token: String) -> Bool {
        token.contains { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isSentenceStart(_ index: Int, _ tokens: [Token]) -> Bool {
        if index == tokens.firstIndex(where: { isWord($0.text) }) { return true }
        return index > 0 && [".", "!", "?"].contains(tokens[index - 1].text)
    }

    private enum AuxiliaryContext { case auxiliary, ambiguous, none }

    private static func auxiliaryContext(_ edit: Edit, _ tokens: [Token], _ language: Language) -> AuxiliaryContext {
        var before = edit.tokenSpan.lowerBound - 1
        while tokens.indices.contains(before), ["'", "’", "t", "not"].contains(tokens[before].text.lowercased()) { before -= 1 }
        if language == .en, edit.tokenSpan.upperBound < tokens.count, tokens[edit.tokenSpan.upperBound].text.lowercased() == "to",
           ["use", "suppose"].contains(edit.original.lowercased()), edit.replacement.lowercased() == edit.original.lowercased() + "d" {
            return .auxiliary
        }
        guard tokens.indices.contains(before) else { return .none }
        let word = tokens[before].text.lowercased()
        if ["ve", "s", "m", "re", "d"].contains(word) {
            guard language == .en, before > 0, ["'", "’"].contains(tokens[before - 1].text) else { return .none }
            return word == "d" ? .ambiguous : .auxiliary
        }
        return FunctionWords.isAuxiliary(word, language) ? .auxiliary : .none
    }

    // MARK: Numbers, URLs, code and names

    private static func isNumberURLCodeOrName(_ edit: Edit, in paragraph: String, tokens: [Token]) -> Bool {
        let chunk = chunk(around: edit.range, in: paragraph)
        if looksLikeNumberURLOrCode(chunk) || looksLikeNumberURLOrCode(edit.replacement) { return true }
        if isHyphenatedName(chunk) { return true }
        return edit.tokenSpan.contains { index in
            let word = tokens[index].text
            guard isWord(word) else { return false }
            return (word.first?.isUppercase == true && !isSentenceStart(index, tokens)) || isAbbreviation(word, in: edit)
        }
    }

    private static func isAbbreviation(_ word: String, in edit: Edit) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2, !fold(letters).contains(where: "aeiouy".contains) else { return false }
        let added = edit.replacement.filter(\.isLetter).count - edit.original.filter(\.isLetter).count
        guard added <= 2, added < letters.count else { return true }
        var rest = Substring(edit.replacement)
        for letter in letters {
            guard let found = rest.firstIndex(of: letter) else { return true }
            rest = rest[rest.index(after: found)...]
        }
        return false
    }

    private static func chunk(around range: TextRange, in paragraph: String) -> String {
        let text = paragraph as NSString
        func isSpace(_ unit: unichar) -> Bool {
            Unicode.Scalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
        }
        var start = min(range.location, text.length)
        var end = min(range.end, text.length)
        while start > 0 && !isSpace(text.character(at: start - 1)) { start -= 1 }
        while end < text.length && !isSpace(text.character(at: end)) { end += 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    private static func core(_ chunk: String) -> String {
        chunk.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "`_")).inverted)
    }

    private static func looksLikeNumberURLOrCode(_ text: String) -> Bool {
        if text.contains(where: \.isNumber) { return true }
        let lowered = text.lowercased()
        if lowered.contains("://") || lowered.contains("www.") { return true }
        let core = core(text)
        if core.contains("`") || core.contains("_") || core.contains("::") { return true }
        return zip(core, core.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }

    private static func isHyphenatedName(_ chunk: String) -> Bool {
        let parts = core(chunk).split(separator: "-", omittingEmptySubsequences: false)
        return parts.count > 1 && parts[0].first?.isUppercase == true
    }

    // MARK: Punctuation and capitalisation

    private static func punctuationVerdict(_ edit: Edit, _ tokens: [Token]) -> GuardVerdict {
        let final: Set<String> = [".", "!", "?"]
        let addsFinal = edit.tokenSpan.isEmpty && edit.tokenSpan.lowerBound == tokens.count
            && !edit.replacementTokens.isEmpty && edit.replacementTokens.allSatisfy(final.contains)
        let endsWithFinal = tokens.last.map { final.contains($0.text) } ?? false
        let otherSentenceEnds = tokens.indices.dropLast().contains {
            final.contains(tokens[$0].text) && isWord(tokens[$0 + 1].text) && tokens[$0 + 1].text.first?.isUppercase == true
                && tokens[$0 + 1].text != "I"
        }
        return addsFinal && !endsWithFinal && !otherSentenceEnds ? .drop(.addedFormality) : .keep
    }

    private static func isCapitalisationOnly(_ edit: Edit) -> Bool {
        edit.original != edit.replacement && edit.original.lowercased() == edit.replacement.lowercased()
    }

    private static func capitalisationVerdict(_ edit: Edit, _ tokens: [Token], _ language: Language) -> GuardVerdict {
        guard edit.original.first?.isLowercase == true, edit.replacement.first?.isUppercase == true else { return .undecided }
        if CalendarNames.contains(edit.original, language) { return language == .en ? .keep : .drop(.addedFormality) }
        let isKnownName = tokens.indices.contains {
            !edit.tokenSpan.contains($0) && tokens[$0].text == edit.replacement && !isSentenceStart($0, tokens)
        }
        if isKnownName { return .keep }
        let index = edit.tokenSpan.lowerBound
        guard isSentenceStart(index, tokens) else { return .undecided }
        let others = tokens.indices.filter {
            $0 != index && isSentenceStart($0, tokens) && tokens[$0].text.first?.isLetter == true && tokens[$0].text != "I"
        }
        if others.isEmpty { return tokens.last?.text == "." ? .keep : .drop(.addedFormality) }
        return others.allSatisfy { tokens[$0].text.first?.isLowercase == true } ? .drop(.addedFormality) : .keep
    }

    // MARK: Words

    private static func fold(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func isCompoundSplit(_ edit: Edit, _ replacement: [String], _ isFunctionWord: (String) -> Bool) -> Bool {
        guard !edit.original.contains(where: \.isWhitespace), edit.replacement.contains(where: \.isWhitespace) else { return false }
        return edit.replacement.filter { !$0.isWhitespace }.lowercased() == edit.original.lowercased() && !replacement.contains(where: isFunctionWord)
    }

    private static func isNearHomophone(_ a: String, _ b: String) -> Bool {
        let x = Array(fold(a)), y = Array(fold(b))
        let prefix = zip(x, y).prefix { $0 == $1 }.count
        let suffix = zip(x[prefix...].reversed(), y[prefix...].reversed()).prefix { $0 == $1 }.count
        return x.count - prefix - suffix <= 2 && y.count - prefix - suffix <= 2
    }

    /// British and American spellings of one word ("colour", "color"): both correct, so swapping one for the
    /// other restyles the text. Both are English, sound alike and are accepted by different dictionaries.
    private static func isSpellingVariant(_ a: String, _ b: String, _ facts: WordFacts) -> Bool {
        func dictionaries(_ word: String) -> (british: Bool, american: Bool) {
            (!facts.americanOnly.contains(word), !facts.britishOnly.contains(word))
        }
        return a != b && facts.english.isSuperset(of: [a, b]) && !facts.misspelled.contains(a) && isNearHomophone(a, b)
            && dictionaries(a) != dictionaries(b)
    }

    private static func englishStem(_ word: String, _ facts: WordFacts) -> String? {
        if let stem = facts.englishStems[word] { return stem }
        return facts.english.contains(word) ? word : nil
    }

    private static func stemKeys(_ stem: String) -> Set<String> {
        let folded = fold(stem)
        var keys: Set<String> = [folded]
        if folded.hasSuffix("es"), folded.count > 3 { keys.insert(String(folded.dropLast(2))) }
        if folded.hasSuffix("s"), folded.count > 2 { keys.insert(String(folded.dropLast())) }
        return keys
    }

    private static func borrowedWordVerdict(_ original: [String], _ replacement: [String], _ facts: WordFacts) -> GuardVerdict? {
        let stems = original.map { englishStem($0, facts) }
        guard stems.contains(where: { $0 != nil }) else { return nil }
        guard original.count == replacement.count else { return .drop(.borrowedWord) }
        for (index, stem) in stems.enumerated() {
            guard let stem else { continue }
            if facts.englishStems[original[index]] != nil && facts.englishStems[replacement[index]] == nil { return .drop(.borrowedWord) }
            let replacementStem = facts.englishStems[replacement[index]] ?? replacement[index]
            guard !stemKeys(stem).isDisjoint(with: stemKeys(replacementStem)), distance(original[index], replacement[index]) <= 2 else {
                return .drop(.borrowedWord)
            }
        }
        return stems.allSatisfy { $0 != nil } ? .keep : nil
    }

    private static func contentVerdict(
        _ original: [String],
        _ replacement: [String],
        _ facts: WordFacts,
        _ language: Language,
        _ isFunctionWord: (String) -> Bool,
        _ auxiliary: AuxiliaryContext
    ) -> GuardVerdict {
        var from = original, to = replacement
        if from.count != to.count {
            from = from.filter { !isFunctionWord($0) }
            to = to.filter { !isFunctionWord($0) }
        }
        guard from.count == to.count, !from.isEmpty else { return .undecided }
        let verdicts = zip(from, to).map { pairVerdict($0, $1, facts, language, isFunctionWord, auxiliary) }
        if let drop = verdicts.first(where: { if case .drop = $0 { true } else { false } }) { return drop }
        return verdicts.contains(.undecided) ? .undecided : .keep
    }

    private static func pairVerdict(
        _ from: String,
        _ to: String,
        _ facts: WordFacts,
        _ language: Language,
        _ isFunctionWord: (String) -> Bool,
        _ auxiliary: AuxiliaryContext
    ) -> GuardVerdict {
        if from == to { return .keep }
        if [from, to].contains(where: { FunctionWords.isPreposition($0, language) }) {
            if fold(from) == fold(to) || isFinalLetterDoubled(from, to) { return .keep }
            return isFunctionWord(from) && isFunctionWord(to) || isNearHomophone(from, to) ? .undecided : .drop(.replacement)
        }
        let sameLemma = facts.lemmas[from] != nil && facts.lemmas[from] == facts.lemmas[to]
        if language == .en && sameLemma && isPastTense(from, facts) != isPastTense(to, facts) { return tenseVerdict(auxiliary) }
        if isNearHomophone(from, to) { return .keep }
        if isFunctionWord(from) && isFunctionWord(to) { return .keep }
        guard let lemma = facts.lemmas[from], facts.lemmas[to] == lemma else { return .drop(.replacement) }
        return tenseVerdict(auxiliary)
    }

    private static func tenseVerdict(_ auxiliary: AuxiliaryContext) -> GuardVerdict {
        switch auxiliary {
        case .auxiliary: .keep
        case .ambiguous: .undecided
        case .none: .drop(.tenseChange)
        }
    }

    private static func isFinalLetterDoubled(_ a: String, _ b: String) -> Bool {
        func doubled(_ short: String, _ long: String) -> Bool {
            guard let last = short.last else { return false }
            return long == short + String(last)
        }
        return doubled(a.lowercased(), b.lowercased()) || doubled(b.lowercased(), a.lowercased())
    }

    private static func isPastTense(_ word: String, _ facts: WordFacts) -> Bool {
        word.hasSuffix("ed") && facts.lemmas[word].map { $0 != word } == true
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() {
                row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = row
        }
        return previous[b.count]
    }
}
