import Foundation
import Testing
@testable import SkaldCore

private let flew = "We flew to teh office in paris yesterday"

private let oracle = FakeWordOracle(dictionary: [
    "en": ["teh": FakeWordOracle.Entry(misspelled: true, english: false, stem: nil, lemma: nil, function: nil)],
])

private actor AskedConfirmer: EditConfirming {
    private(set) var asked: [String] = []

    func confirm(_ edit: Edit, in paragraph: String, language: Language) -> Bool? {
        asked.append(edit.original)
        return true
    }
}

private func judge(_ output: String, confirmer: AskedConfirmer? = nil, mayConfirm: Bool = true) async -> ModelAnswer {
    await ModelAnswer.judge(
        output, for: flew, language: .en, editGuard: EditGuard(neverTouch: []), detector: FakeLanguageDetector(), oracle: oracle,
        confirmer: confirmer
    ) { _ in mayConfirm }
}

@Test func aWrappedAnswerIsCleanedThenResolved() async throws {
    let answer = await judge("Corrected text: \"We flew to the office in paris yesterday\"")
    guard case .kept(let kept) = answer else { Issue.record("discarded: \(answer)"); return }
    #expect(kept.map { "\($0.original) → \($0.replacement)" } == ["teh → the"])
}

@Test func anAnswerInAnotherLanguageIsDiscardedWhole() async {
    #expect(await judge("Ik heb het kantoor gisteren bezocht in Parijs") == .discarded(.languageChanged))
}

@Test func anUndecidedEditIsAskedAboutOnlyWhileConfirmationIsAllowed() async throws {
    let output = "We flew to teh office in Paris yesterday"
    let blocked = AskedConfirmer()
    #expect(await judge(output, confirmer: blocked, mayConfirm: false) == .kept([]))
    #expect(await blocked.asked.isEmpty)

    let allowed = AskedConfirmer()
    guard case .kept(let kept) = await judge(output, confirmer: allowed) else { Issue.record("discarded"); return }
    #expect(kept.map(\.replacement) == ["Paris"])
    #expect(await allowed.asked == ["paris"])
}
