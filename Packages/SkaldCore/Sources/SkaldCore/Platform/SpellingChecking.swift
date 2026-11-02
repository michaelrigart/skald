public protocol SpellingChecking: Sendable {
    /// Raw flags; the caller runs the edit guard.
    func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) async -> [Edit]
}
