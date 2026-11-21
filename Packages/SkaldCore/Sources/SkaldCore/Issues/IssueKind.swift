public enum IssueCategory: String, Codable, CaseIterable, Sendable {
    case spelling, punctuation, grammar

    public var title: String {
        switch self {
        case .spelling: "Spelling"
        case .punctuation: "Punctuation"
        case .grammar: "Grammar"
        }
    }
}

public enum IssueKind: String, Codable, CaseIterable, Sendable {
    case spelling, capital, accent, punctuation, grammar, repeatedWord, verbForm

    public var category: IssueCategory {
        switch self {
        case .spelling, .capital, .accent: .spelling
        case .punctuation: .punctuation
        case .grammar, .repeatedWord, .verbForm: .grammar
        }
    }

    public var title: String {
        switch self {
        case .spelling: "Spelling"
        case .capital: "Capital letter"
        case .accent: "Accent"
        case .punctuation: "Punctuation"
        case .grammar: "Grammar"
        case .repeatedWord: "Repeated word"
        case .verbForm: "Verb form"
        }
    }

    public var isHideable: Bool {
        switch self {
        case .spelling, .grammar: false
        case .capital, .accent, .punctuation, .repeatedWord, .verbForm: true
        }
    }

    /// "Grammar · Verb form"; just "Grammar" for a kind that is its category.
    public var headline: String {
        title == category.title ? title : "\(category.title) · \(title)"
    }
}
