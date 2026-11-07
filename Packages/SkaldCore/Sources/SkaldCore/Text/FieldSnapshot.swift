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
        let keyed = keyed(s)
        guard let parent = Paragraphs.around(caret: caret, in: keyed.map(\.1)),
              let key = keyed.first(where: { $0.1 == parent })?.0
        else { return [] }
        return chunkKeys(of: parent, key: key)
    }

    /// The keyed chunks of one paragraph, given its chunk-0 key.
    static func chunkKeys(of parent: Paragraph, key: ParagraphKey) -> [(ParagraphKey, chunk: Paragraph, parent: Paragraph)] {
        Paragraphs.chunks(parent).enumerated().map { index, chunk in
            (key.withChunk(index), chunk, parent)
        }
    }

    /// Every paragraph in the snapshot, by its chunk-0 key.
    static func parents(in s: FieldSnapshot) -> [ParagraphKey: Paragraph] {
        parents(keyed(s))
    }

    static func parents(_ keyed: [(ParagraphKey, Paragraph)]) -> [ParagraphKey: Paragraph] {
        Dictionary(keyed, uniquingKeysWith: { first, _ in first })
    }

    /// True when a read shows that `key`, which `locate` did not find in it, is gone: any key of a whole-field
    /// read, an occurrence key of any read (the field grew past the read limit and its keys changed kind), and a
    /// location key whose paragraph lies inside the read's window or past the field's end.
    static func isGone(_ key: ParagraphKey, in s: FieldSnapshot) -> Bool {
        switch key.position {
        case .occurrence:
            return true
        case .location(let location):
            let window = s.offset...(s.offset + s.text.utf16.count)
            let end = location + key.text.utf16.count
            return s.holdsWholeField || end > s.totalLength || (window.contains(location) && window.contains(end))
        }
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
