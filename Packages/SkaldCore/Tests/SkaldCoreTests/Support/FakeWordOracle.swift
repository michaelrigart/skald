import Foundation
@testable import SkaldCore

/// Answers from `Fixtures/guard/word-facts.json`, which holds what `NSSpellChecker` and `NLTagger` returned
/// on macOS 27.2 for every word the guard's tests touch. Dutch has no lemmas, as measured.
actor FakeWordOracle: WordOracle {
    struct Entry: Decodable, Sendable {
        let misspelled: Bool
        let english: Bool
        let stem: String?
        let lemma: String?
        let function: Bool?
    }

    struct Request: Equatable, Sendable {
        let words: Set<String>
        let language: Language
    }

    private let dictionary: [String: [String: Entry]]
    private(set) var requests: [Request] = []
    private(set) var unknownWords: Set<String> = []

    init(dictionary: [String: [String: Entry]]) {
        self.dictionary = dictionary
    }

    static func measured() throws -> FakeWordOracle {
        let data = try Data(contentsOf: Fixtures.wordFacts)
        return FakeWordOracle(dictionary: try JSONDecoder().decode([String: [String: Entry]].self, from: data))
    }

    func facts(for words: Set<String>, language: Language) -> WordFacts {
        requests.append(Request(words: words, language: language))
        let entries = dictionary[language.rawValue] ?? [:]
        var facts = WordFacts()
        for word in words {
            guard let entry = entries[word] else {
                unknownWords.insert("\(language.rawValue):\(word)")
                continue
            }
            if entry.misspelled { facts.misspelled.insert(word) }
            if entry.english { facts.english.insert(word) }
            if let stem = entry.stem { facts.englishStems[word] = stem }
            if let lemma = entry.lemma { facts.lemmas[word] = lemma }
            if entry.function == true { facts.functionWords.insert(word) }
        }
        return facts
    }
}
