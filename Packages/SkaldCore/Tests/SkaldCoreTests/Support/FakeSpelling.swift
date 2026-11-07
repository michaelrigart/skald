import Foundation
@testable import SkaldCore

/// Flags every whole-word occurrence of a listed misspelling, one edit per occurrence, as the system checker
/// does. It ignores `neverTouch` on purpose, so tests see the pipeline's guard drop those flags.
actor FakeSpelling: SpellingChecking {
    struct Call: Equatable, Sendable {
        let text: String
        let language: Language
        let neverTouch: Set<String>
    }

    private let misspellings: [String: String]
    private(set) var calls: [Call] = []
    private var heldTexts: [String: CallGate] = [:]

    init(_ misspellings: [String: String]) {
        self.misspellings = misspellings
    }

    /// Holds the first call for `text` until it is released or the hold is opened; later calls for it pass.
    func hold(_ text: String) {
        heldTexts[text] = CallGate(closed: true)
    }

    func release(_ text: String) {
        heldTexts[text]?.release(0)
    }

    func waitForCalls(of text: String, _ count: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { heldTexts[text]?.wait(id, for: count, $0) }
        } onCancel: {
            Task { await self.stopWaiting(for: text, id) }
        }
    }

    private func stopWaiting(for text: String, _ id: UUID) {
        heldTexts[text]?.stopWaiting(id)
    }

    func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) async -> [Edit] {
        calls.append(Call(text: p.text, language: language, neverTouch: neverTouch))
        if let index = heldTexts[p.text]?.arrive(), index == 0, heldTexts[p.text]?.mustWait(0) == true {
            await withCheckedContinuation { heldTexts[p.text]?.hold(0, $0) }
        }
        let text = p.text as NSString
        return Tokenizer.tokens(in: p.text).flatMap { token -> [Edit] in
            guard let suggestion = misspellings[token.text] else { return [] }
            let revised = text.replacingCharacters(in: NSRange(location: token.range.location, length: token.range.length), with: suggestion)
            return TextDiff.edits(from: p.text, to: revised)
        }
    }

    var texts: [String] { calls.map(\.text) }

    func calls(of text: String) -> [Call] {
        calls.filter { $0.text == text }
    }
}
