public struct WordFacts: Sendable, Equatable {
    public var misspelled: Set<String>
    public var english: Set<String>
    public var englishStems: [String: String]
    public var lemmas: [String: String]
    public var functionWords: Set<String>

    public init(
        misspelled: Set<String> = [],
        english: Set<String> = [],
        englishStems: [String: String] = [:],
        lemmas: [String: String] = [:],
        functionWords: Set<String> = []
    ) {
        self.misspelled = misspelled
        self.english = english
        self.englishStems = englishStems
        self.lemmas = lemmas
        self.functionWords = functionWords
    }
}
