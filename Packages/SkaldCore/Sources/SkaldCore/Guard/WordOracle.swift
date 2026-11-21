public protocol WordOracle: Sendable {
    func facts(for words: Set<String>, language: Language) async -> WordFacts
}

public protocol EditConfirming: Sendable {
    func confirm(_ edit: Edit, in paragraph: String, language: Language) async -> Bool?
}
