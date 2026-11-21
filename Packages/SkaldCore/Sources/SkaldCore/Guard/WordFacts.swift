public struct WordFacts: Sendable, Equatable {
    public var misspelled: Set<String>
    public var english: Set<String>
    /// English words only the British dictionary accepts, and only the American one; the rest of `english` both accept.
    public var britishOnly: Set<String>
    public var americanOnly: Set<String>
    public var englishStems: [String: String]
    public var lemmas: [String: String]
    public var functionWords: Set<String>

    public init(
        misspelled: Set<String> = [],
        english: Set<String> = [],
        britishOnly: Set<String> = [],
        americanOnly: Set<String> = [],
        englishStems: [String: String] = [:],
        lemmas: [String: String] = [:],
        functionWords: Set<String> = []
    ) {
        self.misspelled = misspelled
        self.english = english
        self.britishOnly = britishOnly
        self.americanOnly = americanOnly
        self.englishStems = englishStems
        self.lemmas = lemmas
        self.functionWords = functionWords
    }
}
