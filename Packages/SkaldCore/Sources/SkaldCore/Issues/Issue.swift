import Foundation

public struct Issue: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let key: ParagraphKey
    public let parent: Paragraph
    public let chunk: Paragraph
    /// Relative to `chunk`.
    public let edit: Edit
    public let source: IssueSource
    public let language: Language
    /// The engine that found a model issue; nil for spelling.
    public let engine: EngineKind?
    public let kind: IssueKind
    /// The checker's other guesses over the same range, relative to `chunk` like `edit`.
    public let alternatives: [Edit]

    public init(
        id: UUID = UUID(),
        key: ParagraphKey,
        parent: Paragraph,
        chunk: Paragraph,
        edit: Edit,
        source: IssueSource,
        language: Language,
        engine: EngineKind? = nil,
        kind: IssueKind? = nil,
        alternatives: [Edit] = []
    ) {
        self.id = id
        self.key = key
        self.parent = parent
        self.chunk = chunk
        self.edit = edit
        self.source = source
        self.language = language
        self.engine = engine
        self.kind = kind ?? (source == .spelling ? .spelling : .grammar)
        self.alternatives = alternatives
    }

    /// The same issue, with only the alternatives `keep` accepts.
    func keepingAlternatives(where keep: (Edit) -> Bool) -> Issue {
        Issue(
            id: id, key: key, parent: parent, chunk: chunk, edit: edit, source: source, language: language, engine: engine,
            kind: kind, alternatives: alternatives.filter(keep)
        )
    }

    public var fieldRange: TextRange {
        TextRange(location: chunk.range.location + edit.range.location, length: edit.range.length)
    }

    public var word: String { edit.original }

    public var expected: ExpectedText {
        ExpectedText(range: parent.range, text: parent.text)
    }
}
