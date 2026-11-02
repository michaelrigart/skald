public protocol LanguageDetecting: Sendable {
    func detect(_ text: String, previous: Language?) -> Language?
}
