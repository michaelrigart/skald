import Foundation

public struct FieldID: Hashable, Sendable {
    public let app: String
    public let token: String

    public init(app: String, token: String) {
        self.app = app
        self.token = token
    }
}

public struct FieldSnapshot: Equatable, Sendable {
    public let field: FieldID
    /// The read window, starting at field offset `offset`.
    public let text: String
    public let offset: Int
    public let selection: TextRange
    public let totalLength: Int

    public init(field: FieldID, text: String, offset: Int, selection: TextRange, totalLength: Int) {
        self.field = field
        self.text = text
        self.offset = offset
        self.selection = selection
        self.totalLength = totalLength
    }

    var holdsWholeField: Bool {
        offset == 0 && text.utf16.count == totalLength
    }
}

public enum ParagraphPosition: Hashable, Sendable {
    case occurrence(Int), location(Int)
}

public struct ParagraphKey: Hashable, Sendable {
    public let field: FieldID
    /// The whole parent paragraph, even for a chunk.
    public let text: String
    public let position: ParagraphPosition
    public let chunk: Int

    public init(field: FieldID, text: String, position: ParagraphPosition, chunk: Int) {
        self.field = field
        self.text = text
        self.position = position
        self.chunk = chunk
    }

    func withChunk(_ chunk: Int) -> ParagraphKey {
        ParagraphKey(field: field, text: text, position: position, chunk: chunk)
    }
}

public enum ParagraphKeys {
    public static func keyed(_ s: FieldSnapshot) -> [(ParagraphKey, Paragraph)] {
        keyedParagraphs(Paragraphs.all(in: s.text, offset: s.offset), in: s)
    }

    public static func chunkKeys(_ s: FieldSnapshot, caret: Int) -> [(ParagraphKey, chunk: Paragraph, parent: Paragraph)] {
        guard let parent = Paragraphs.around(caret: caret, in: s.text, offset: s.offset),
              let key = keyed(s).first(where: { $0.1 == parent })?.0
        else { return [] }
        return Paragraphs.chunks(parent).enumerated().map { index, chunk in
            (key.withChunk(index), chunk, parent)
        }
    }

    /// Every paragraph in the snapshot, by its chunk-0 key.
    static func parents(in s: FieldSnapshot) -> [ParagraphKey: Paragraph] {
        Dictionary(keyed(s), uniquingKeysWith: { first, _ in first })
    }

    /// The parent paragraph and chunk that `key` names among `parents`, or nil when they no longer hold it.
    static func locate(_ key: ParagraphKey, in parents: [ParagraphKey: Paragraph]) -> (parent: Paragraph, chunk: Paragraph)? {
        guard let parent = parents[key.withChunk(0)] else { return nil }
        let chunks = Paragraphs.chunks(parent)
        guard key.chunk < chunks.count else { return nil }
        return (parent, chunks[key.chunk])
    }

    private static func keyedParagraphs(_ paragraphs: [Paragraph], in s: FieldSnapshot) -> [(ParagraphKey, Paragraph)] {
        let whole = s.holdsWholeField
        var seen: [String: Int] = [:]
        return paragraphs.map { paragraph in
            let position: ParagraphPosition
            if whole {
                let n = seen[paragraph.text, default: 0]
                seen[paragraph.text] = n + 1
                position = .occurrence(n)
            } else {
                position = .location(paragraph.range.location)
            }
            return (ParagraphKey(field: s.field, text: paragraph.text, position: position, chunk: 0), paragraph)
        }
    }
}
