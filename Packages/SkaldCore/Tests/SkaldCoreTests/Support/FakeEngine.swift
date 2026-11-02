import Foundation
@testable import SkaldCore

/// Answers each request with `answer`. While gated, every call waits for `release` or `open`, and it
/// ignores cancellation, like an engine that answers late, so the caller's own checks are what drop it.
actor FakeEngine: Engine {
    nonisolated let kind = EngineKind.thisMac
    private let answer: @Sendable (EngineRequest, Int) -> Result<String, EngineFailure>
    private var gate: CallGate
    private(set) var requests: [EngineRequest] = []
    /// Indices of calls whose task was cancelled by the time they answered.
    private(set) var cancelled: [Int] = []

    init(gated: Bool = false, answer: @escaping @Sendable (EngineRequest, Int) -> Result<String, EngineFailure>) {
        gate = CallGate(closed: gated)
        self.answer = answer
    }

    /// Replaces whole words, keeping everything else as given.
    static func correcting(_ corrections: [String: String], gated: Bool = false) -> FakeEngine {
        FakeEngine(gated: gated) { request, _ in .success(replacingWords(in: request.text, corrections)) }
    }

    func run(_ r: EngineRequest) async throws(EngineFailure) -> String {
        requests.append(r)
        let index = gate.arrive()
        if gate.mustWait(index) {
            await withCheckedContinuation { gate.hold(index, $0) }
        }
        if Task.isCancelled { cancelled.append(index) }
        return try answer(r, index).get()
    }

    var texts: [String] { requests.map(\.text) }

    func waitForRequests(_ count: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate.wait(id, for: count, $0) }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: UUID) {
        gate.stopWaiting(id)
    }

    func release(_ index: Int) {
        gate.release(index)
    }

    func open() {
        gate.open()
    }
}

func replacingWords(in text: String, _ corrections: [String: String]) -> String {
    let result = NSMutableString(string: text)
    for token in Tokenizer.tokens(in: text).reversed() {
        guard let replacement = corrections[token.text] else { continue }
        result.replaceCharacters(in: NSRange(location: token.range.location, length: token.range.length), with: replacement)
    }
    return result as String
}
