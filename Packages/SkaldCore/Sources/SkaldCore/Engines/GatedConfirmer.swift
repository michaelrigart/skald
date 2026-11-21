public struct GatedConfirmer: EditConfirming {
    private let inner: any EditConfirming
    private let gate: @Sendable (Language) async -> Bool

    public init(inner: any EditConfirming, gate: @escaping @Sendable (Language) async -> Bool) {
        self.inner = inner
        self.gate = gate
    }

    public func confirm(_ edit: Edit, in paragraph: String, language: Language) async -> Bool? {
        guard await gate(language) else { return nil }
        return await inner.confirm(edit, in: paragraph, language: language)
    }
}
