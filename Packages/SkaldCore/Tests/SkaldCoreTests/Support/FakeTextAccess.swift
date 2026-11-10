import Foundation
@testable import SkaldCore
import struct SkaldCore.TextRange

/// Fields held in memory. Reads are counted and windowed around the caret like the real reader. While snapshots
/// are held, each read takes the text when it starts and returns it only once the test releases it.
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
    private var snapshotGate = CallGate(closed: false)

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

    /// Holds every snapshot read from now on; their indices count from 0 again.
    func holdSnapshots() {
        snapshotGate = CallGate(closed: true)
    }

    func releaseSnapshot(_ index: Int) {
        snapshotGate.release(index)
    }

    func stopHoldingSnapshots() {
        snapshotGate.open()
    }

    func waitForSnapshots(_ count: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { snapshotGate.wait(id, for: count, $0) }
        } onCancel: {
            Task { await self.stopWaitingForSnapshots(id) }
        }
    }

    private func stopWaitingForSnapshots(_ id: UUID) {
        snapshotGate.stopWaiting(id)
    }

    func snapshot(of field: FieldID) async -> FieldSnapshot? {
        reads += 1
        let snapshot = fields[field].map { text, caret in
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
        let index = snapshotGate.arrive()
        if snapshotGate.mustWait(index) {
            await withCheckedContinuation { snapshotGate.hold(index, $0) }
        }
        return snapshot
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
