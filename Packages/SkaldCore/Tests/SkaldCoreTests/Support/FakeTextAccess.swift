import Foundation
@testable import SkaldCore
import struct SkaldCore.TextRange

/// Fields held in memory. Reads are counted and windowed around the caret like the real reader.
actor FakeTextAccess: TextAccess {
    struct Replacement: Equatable, Sendable {
        let range: TextRange
        let expected: ExpectedText
        let text: String
        let field: FieldID
    }

    nonisolated let events: AsyncStream<FieldEvent>
    private nonisolated let continuation: AsyncStream<FieldEvent>.Continuation
    private var fields: [FieldID: (text: String, caret: Int)] = [:]
    private(set) var reads = 0
    private(set) var replacements: [Replacement] = []
    private var outcome = ReplaceOutcome.replaced

    init() {
        (events, continuation) = AsyncStream.makeStream(of: FieldEvent.self)
    }

    nonisolated func send(_ event: FieldEvent) {
        continuation.yield(event)
    }

    func set(_ text: String, caret: Int, in field: FieldID) {
        fields[field] = (text, caret)
    }

    func moveCaret(to caret: Int, in field: FieldID) {
        fields[field]?.caret = caret
    }

    func answerReplacements(with outcome: ReplaceOutcome) {
        self.outcome = outcome
    }

    func snapshot(of field: FieldID) -> FieldSnapshot? {
        reads += 1
        guard let (text, caret) = fields[field] else { return nil }
        let total = text.utf16.count
        let window = ReadWindow.range(totalLength: total, caret: caret)
        return FieldSnapshot(
            field: field,
            text: (text as NSString).substring(with: NSRange(location: window.location, length: window.length)),
            offset: window.location,
            selection: TextRange(location: caret, length: 0),
            totalLength: total
        )
    }

    func capabilities(for app: String) -> AccessCapabilities {
        [.read, .rangeBounds, .fieldFrame, .cleanWrite]
    }

    func capture(of field: FieldID) -> SelectionCapture? {
        nil
    }

    func replace(_ range: TextRange, expected: ExpectedText, with text: String, in field: FieldID) -> ReplaceOutcome {
        replacements.append(Replacement(range: range, expected: expected, text: text, field: field))
        return outcome
    }
}
