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

    public init(
        id: UUID = UUID(),
        key: ParagraphKey,
        parent: Paragraph,
        chunk: Paragraph,
        edit: Edit,
        source: IssueSource,
        language: Language
    ) {
        self.id = id
        self.key = key
        self.parent = parent
        self.chunk = chunk
        self.edit = edit
        self.source = source
        self.language = language
    }

    public var fieldRange: TextRange {
        TextRange(location: chunk.range.location + edit.range.location, length: edit.range.length)
    }

    public var word: String { edit.original }

    public var expected: ExpectedText {
        ExpectedText(range: parent.range, text: parent.text)
    }
}
