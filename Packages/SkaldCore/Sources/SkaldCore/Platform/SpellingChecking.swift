/// What the spell checker found for one misspelling: its first guess as an edit, and every further guess over the
/// same range.
public struct SpellingFlag: Equatable, Sendable {
    /// The first guess (an empty replacement when there is none).
    public let edit: Edit
    /// Every further guess over the same `range`, in the checker's order.
    public let alternatives: [Edit]

    public init(edit: Edit, alternatives: [Edit] = []) {
        self.edit = edit
        self.alternatives = alternatives
    }
}

public protocol SpellingChecking: Sendable {
    /// Raw flags; the caller runs the edit guard.
    func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) async -> [SpellingFlag]
}
