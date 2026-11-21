import Foundation
import Testing
@testable import SkaldCore

private final class RecordingConfirmer: EditConfirming, @unchecked Sendable { // reason: calls are guarded by a lock
    private let lock = NSLock()
    private var recorded = 0
    let answer: Bool?

    init(answer: Bool?) { self.answer = answer }

    var calls: Int { lock.withLock { recorded } }

    func confirm(_ edit: Edit, in paragraph: String, language: Language) async -> Bool? {
        lock.withLock { recorded += 1 }
        return answer
    }
}

private final class Switch: @unchecked Sendable { // reason: the flag is guarded by a lock
    private let lock = NSLock()
    private var value: Bool
    private var asked: [Language] = []

    init(_ value: Bool) { self.value = value }

    func set(_ new: Bool) { lock.withLock { value = new } }
    var languages: [Language] { lock.withLock { asked } }
    func read(_ language: Language) -> Bool { lock.withLock { asked.append(language); return value } }
}

private let sampleEdit: Edit = {
    TextDiff.edits(from: "I has a dog", to: "I have a dog")[0]
}()

@Test func aClosedGateReturnsNilWithoutCallingTheInnerConfirmer() async {
    let inner = RecordingConfirmer(answer: true)
    let confirmer = GatedConfirmer(inner: inner, gate: { _ in false })
    #expect(await confirmer.confirm(sampleEdit, in: "I has a dog", language: .en) == nil)
    #expect(inner.calls == 0)
}

@Test func anOpenGatePassesTheInnerAnswerThrough() async {
    for answer in [true, false, nil] as [Bool?] {
        let inner = RecordingConfirmer(answer: answer)
        let confirmer = GatedConfirmer(inner: inner, gate: { _ in true })
        #expect(await confirmer.confirm(sampleEdit, in: "I has a dog", language: .en) == answer)
        #expect(inner.calls == 1)
    }
}

@Test func theGateIsEvaluatedAgainOnEveryCallWithTheCallsLanguage() async {
    let inner = RecordingConfirmer(answer: true)
    let gate = Switch(true)
    let confirmer = GatedConfirmer(inner: inner, gate: { gate.read($0) })
    #expect(await confirmer.confirm(sampleEdit, in: "I has a dog", language: .en) == true)
    gate.set(false)
    #expect(await confirmer.confirm(sampleEdit, in: "I has a dog", language: .nl) == nil)
    gate.set(true)
    #expect(await confirmer.confirm(sampleEdit, in: "I has a dog", language: .fr) == true)
    #expect(gate.languages == [.en, .nl, .fr])
    #expect(inner.calls == 2)
}
