import AppKit
import NaturalLanguage
import SkaldCore

public final class SystemWordOracle: WordOracle {
    private let queue: SpellQueue

    public convenience init() {
        self.init(queue: .shared)
    }

    init(queue: SpellQueue) {
        self.queue = queue
    }

    public func facts(for words: Set<String>, language: Language) async -> WordFacts {
        guard !words.isEmpty else { return WordFacts() }
        return await queue.run { Self.lookup(words, language) }
    }

    private static func lookup(_ words: Set<String>, _ language: Language) -> WordFacts {
        let checker = NSSpellChecker.shared
        func flags(_ word: String, _ dictionary: String) -> Bool {
            checker.checkSpelling(of: word, startingAt: 0, language: dictionary, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                .location != NSNotFound
        }
        func acceptedAsEnglish(_ word: String) -> Bool {
            !flags(word, "en") || !flags(word, "en_GB")
        }

        var facts = WordFacts()
        let lemmaTagger = language == .nl ? nil : NLTagger(tagSchemes: [.lemma])
        let classTagger = language == .nl ? nil : NLTagger(tagSchemes: [.lexicalClass])
        for word in words {
            let misspelled = language == .en ? flags(word, "en") && flags(word, "en_GB") : flags(word, language.rawValue)
            if misspelled { facts.misspelled.insert(word) }
            if acceptedAsEnglish(word) { facts.english.insert(word) }
            if let stem = englishStem(of: word, language, accepted: acceptedAsEnglish) { facts.englishStems[word] = stem }
            if let lemmaTagger, let lemma = tag(word, language, .lemma, lemmaTagger) { facts.lemmas[word] = lemma.lowercased() }
            if FunctionWords.contains(word, language) {
                facts.functionWords.insert(word)
            } else if let classTagger, let tag = tag(word, language, .lexicalClass, classTagger),
                      [NLTag.pronoun, .conjunction, .particle].contains(NLTag(rawValue: tag)) {
                facts.functionWords.insert(word)
            }
        }
        return facts
    }

    private static func tag(_ word: String, _ language: Language, _ scheme: NLTagScheme, _ tagger: NLTagger) -> String? {
        tagger.string = word
        tagger.setLanguage(language == .en ? .english : language == .fr ? .french : .dutch, range: word.startIndex..<word.endIndex)
        return tagger.tag(at: word.startIndex, unit: .word, scheme: scheme).0?.rawValue
    }

    private static func englishStem(of word: String, _ language: Language, accepted: (String) -> Bool) -> String? {
        for stem in stems(of: word, language) where !stem.isEmpty {
            for candidate in [stem, stem + "e"] where accepted(candidate) { return candidate }
        }
        return nil
    }

    private static func stems(of word: String, _ language: Language) -> [String] {
        func dropping(_ suffix: String) -> String? {
            word.hasSuffix(suffix) && word.count > suffix.count ? String(word.dropLast(suffix.count)) : nil
        }
        func participle(_ ending: String) -> String? {
            guard word.hasPrefix("ge"), let stem = dropping(ending) else { return nil }
            return String(stem.dropFirst(2))
        }
        switch language {
        case .en: return []
        case .nl: return [participle("d"), participle("t"), dropping("t"), dropping("en"), dropping("de"), dropping("te")].compactMap { $0 }
        case .fr: return ["ées", "ée", "és", "é", "er"].compactMap(dropping)
        }
    }
}
