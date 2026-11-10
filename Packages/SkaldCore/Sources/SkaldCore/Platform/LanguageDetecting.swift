public protocol LanguageDetecting: Sendable {
    func detect(_ text: String, previous: Language?) -> Language?
}

extension LanguageDetecting {
    /// The one rule for a paragraph's language, shared by checking while typing and the panel. A paragraph the
    /// detector can't place (too short, or a low-confidence one of any length) takes, in order: the field's last
    /// confident language; the language of the nearest paragraph of `read` that detects, above before below; the
    /// language of the whole `read` text, since mixed text can detect as one language throughout. Else nil: a
    /// language is never assumed. Without a `read`, only the first two steps apply.
    func language(
        of paragraph: Paragraph, field: Language?, read: (paragraphs: [Paragraph], text: String)?
    ) -> Language? {
        if let language = detect(paragraph.text, previous: field) ?? field { return language }
        guard let read else { return nil }
        let above = read.paragraphs.filter { $0.range.end <= paragraph.range.location }.reversed()
        let below = read.paragraphs.filter { $0.range.location >= paragraph.range.end }
        for neighbour in above + below {
            if let language = detect(neighbour.text, previous: nil) { return language }
        }
        return detect(read.text, previous: nil)
    }
}
