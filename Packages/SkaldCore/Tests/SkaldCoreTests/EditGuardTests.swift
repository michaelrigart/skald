import Foundation
import SkaldCoreTestSupport
import Testing
@testable import SkaldCore

private func edits(_ row: Row) -> [Edit] {
    TextDiff.edits(from: row.paragraph, to: row.revised)
}

@Test("The spec's outcome table", arguments: outcomeTable + measuredGuesses)
private func outcome(_ row: Row) async throws {
    let found = edits(row)
    try #require(found.count == 1)
    let oracle = try FakeWordOracle.measured()
    let facts = await oracle.facts(for: EditGuard.words(in: found), language: row.language)
    let verdict = EditGuard(neverTouch: row.neverTouch)
        .verdict(for: found[0], in: row.paragraph, language: row.language, source: row.source, facts: facts)
    #expect(verdict == row.expected)
    #expect(await oracle.unknownWords.isEmpty)
}

@Test func anEditIsJudgedOnAllItsWords() {
    let paragraph = "Les tests passent sans problème."
    let revised = "Les tests se déroulent sans problème."
    let found = TextDiff.edits(from: paragraph, to: revised)
    let facts = WordFacts(lemmas: ["passent": "passer", "déroulent": "dérouler"])
    let plain = EditGuard(neverTouch: [])
    #expect(plain.verdict(for: found[0], in: paragraph, language: .fr, source: .model, facts: facts) == .drop(.replacement))
    let guarded = EditGuard(neverTouch: ["déroulent"])
    #expect(guarded.verdict(for: found[0], in: paragraph, language: .fr, source: .model, facts: facts) == .drop(.neverTouch))
}

@Test func functionWordsFromTheOracleAreHonoured() {
    let paragraph = "Ik zie foo hier."
    let found = TextDiff.edits(from: paragraph, to: "Ik zie bar hier.")
    let guardrail = EditGuard(neverTouch: [])
    #expect(guardrail.verdict(for: found[0], in: paragraph, language: .nl, source: .model, facts: WordFacts()) == .drop(.replacement))
    let facts = WordFacts(functionWords: ["foo", "bar"])
    #expect(guardrail.verdict(for: found[0], in: paragraph, language: .nl, source: .model, facts: facts) == .keep)
}

@Test func aSpellingProposalWithNoReplacementIsDroppedButAModelDeletionIsNot() {
    let paragraph = "We hebben de de migratie getest."
    let found = TextDiff.edits(from: paragraph, to: "We hebben de migratie getest.")
    let guardrail = EditGuard(neverTouch: [])
    #expect(guardrail.verdict(for: found[0], in: paragraph, language: .nl, source: .spelling, facts: WordFacts()) == .drop(.noSuggestion))
    #expect(guardrail.verdict(for: found[0], in: paragraph, language: .nl, source: .model, facts: WordFacts()) == .keep)
}

@Test func theBorrowedWordRuleAppliesOnlyToDutchAndFrench() {
    let paragraph = "Il a mergé le correctif."
    let found = TextDiff.edits(from: paragraph, to: "Il a fusionné le correctif.")
    let facts = WordFacts(misspelled: ["mergé"], englishStems: ["mergé": "merge"])
    let verdict = EditGuard(neverTouch: [])
        .verdict(for: found[0], in: paragraph, language: .fr, source: .model, facts: facts)
    #expect(verdict == .drop(.borrowedWord))
    let english = EditGuard(neverTouch: [])
        .verdict(for: found[0], in: paragraph, language: .en, source: .model, facts: facts)
    #expect(english == .keep)
}

@Test func diacriticsDoNotSeparateTheSameBorrowedStem() {
    let paragraph = "Nous avons deja testé."
    let found = TextDiff.edits(from: paragraph, to: "Nous avons déjà testé.")
    let facts = WordFacts(misspelled: ["deja"], english: ["deja", "déjà"])
    let verdict = EditGuard(neverTouch: [])
        .verdict(for: found[0], in: paragraph, language: .fr, source: .spelling, facts: facts)
    #expect(verdict == .keep)
}

@Test func aBorrowedWordChangedByMoreThanTwoLettersIsDropped() {
    let paragraph = "Hij reviewt de commit."
    let found = TextDiff.edits(from: paragraph, to: "Hij reviewden de commit.")
    let facts = WordFacts(englishStems: ["reviewt": "review", "reviewden": "review"])
    let verdict = EditGuard(neverTouch: [])
        .verdict(for: found[0], in: paragraph, language: .nl, source: .model, facts: facts)
    #expect(verdict == .drop(.borrowedWord))
}

private func output(_ run: String, _ id: String) throws -> String {
    let outputs: [EvalOutput] = try EvalScorer.loadJSONL(Fixtures.url(run))
    return try #require(outputs.first { $0.id == id }?.output)
}

@Test func theWholeResultIsDiscardedWhenTheModelTranslatedIt() {
    let c = spike["en2"]!
    let dutch = "De nieuwe implementatiepijplijn draait elke nacht om twee uur, maar de status wordt nog nergens gemeld."
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: c.text, revised: dutch, language: .en, revisedLanguage: .nl)
    #expect(result == .discarded(.languageChanged))
}

@Test func theWholeResultIsKeptWhenItIsAFix() throws {
    let c = spike["en1"]!
    let revised = try output("out-apple-v3", "en1")
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: c.text, revised: revised, language: .en, revisedLanguage: .en)
    #expect(result == .accepted)
}

@Test func theWholeResultIsDiscardedWhenTheModelAppendedText() {
    let original = "Thanks for the fix."
    let revised = original + " I also updated the runbook and the dashboards so everybody can find them."
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: original, revised: revised, language: .en, revisedLanguage: .en)
    #expect(result == .discarded(.tooManyChanges))
}

@Test(arguments: [
    ("Lets ship it.", "Let's ship it."),
    ("Its not working on staging.", "It's not working on staging."),
    ("dont merge yet", "don't merge yet"),
    ("teh", "the"),
    ("Hi Sarah thanks for the fix", "Hi Sarah, thanks, for the fix."),
    ("hey sarah can you deploy it today", "Hey Sarah, can you deploy it today?"),
])
private func aSmallFixIsNeverTooManyChanges(_ pair: (String, String)) {
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: pair.0, revised: pair.1, language: .en, revisedLanguage: .en)
    #expect(result == .accepted)
}

@Test func theWholeResultIsKeptWhenNoLanguageWasDetected() {
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: "Ik heb het gedaan.", revised: "Ik heb het gedaan!", language: .nl, revisedLanguage: nil)
    #expect(result == .accepted)
}

private func numbered(_ prefix: String, _ count: Int) -> String {
    (1...count).map { "\(prefix)\($0)" }.joined(separator: " ")
}

@Test func theWholeResultIsDiscardedWhenNineOfTwentyTokensChanged() {
    let original = numbered("w", 20)
    let revised = (1...20).map { ($0 <= 9 ? "x" : "w") + "\($0)" }.joined(separator: " ")
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: original, revised: revised, language: .en, revisedLanguage: .en)
    #expect(result == .discarded(.tooManyChanges))
}

@Test func theChangeShareCountsScatteredChanges() {
    let original = numbered("w", 20)
    let revised = (1...20).map { ($0.isMultiple(of: 2) && $0 <= 18 ? "x" : "w") + "\($0)" }.joined(separator: " ")
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: original, revised: revised, language: .en, revisedLanguage: .en)
    #expect(result == .discarded(.tooManyChanges))
}

@Test func theWholeResultIsKeptAtExactlyTheChangeShareLimit() {
    let original = numbered("w", 20)
    let revised = (1...20).map { ($0 <= 8 ? "x" : "w") + "\($0)" }.joined(separator: " ")
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: original, revised: revised, language: .en, revisedLanguage: .en)
    #expect(result == .accepted)
}

@Test func theChangeShareLimitIsConfigurable() {
    let original = numbered("w", 20)
    let revised = (1...20).map { ($0 <= 8 ? "x" : "w") + "\($0)" }.joined(separator: " ")
    let result = EditGuard(neverTouch: [], maxChangeShare: 0.3)
        .judgeWhole(original: original, revised: revised, language: .en, revisedLanguage: .en)
    #expect(result == .discarded(.tooManyChanges))
}

@Test(arguments: ["", "  \n "])
private func anEmptyResultIsDiscarded(_ revised: String) {
    let result = EditGuard(neverTouch: [])
        .judgeWhole(original: "Ik heb het gedaan.", revised: revised, language: .nl, revisedLanguage: nil)
    #expect(result == .discarded(.empty))
}

private actor StubConfirmer: EditConfirming {
    let answer: Bool?
    private(set) var asked: [String] = []

    init(_ answer: Bool?) { self.answer = answer }

    func confirm(_ edit: Edit, in paragraph: String, language: Language) -> Bool? {
        asked.append(edit.original)
        return answer
    }
}

private func resolve(_ id: String, confirmer: StubConfirmer?) async throws -> (kept: [Edit], oracle: FakeWordOracle) {
    let c = spike[id]!
    let oracle = try FakeWordOracle.measured()
    let edits = TextDiff.edits(from: c.text, to: c.ref)
    let kept = await EditGuard(neverTouch: [])
        .resolve(edits, in: c.text, language: c.lang, source: .model, oracle: oracle, confirmer: confirmer)
    return (kept, oracle)
}

@Test func resolveAsksTheOracleOnceForEveryWordOfEveryEdit() async throws {
    let (kept, oracle) = try await resolve("en1", confirmer: nil)
    #expect(kept.map(\.original) == ["went", "their"])
    let requests = await oracle.requests
    #expect(requests == [.init(words: ["went", "gone", "their", "there"], language: .en)])
}

@Test func resolveDoesNotAskTheOracleWhenThereAreNoEdits() async throws {
    let oracle = try FakeWordOracle.measured()
    let kept = await EditGuard(neverTouch: [])
        .resolve([], in: "Alles klopt.", language: .nl, source: .model, oracle: oracle, confirmer: nil)
    #expect(kept.isEmpty)
    #expect(await oracle.requests.isEmpty)
}

private func wordtAndVoor() -> (paragraph: String, edits: [Edit]) {
    let c = spike["nl1"]!
    return (c.text, TextDiff.edits(from: c.text, to: swap(c.ref, "om", "voor")))
}

@Test func resolveDropsAnUndecidedEditWhenThereIsNoConfirmer() async throws {
    let (paragraph, edits) = wordtAndVoor()
    let kept = await EditGuard(neverTouch: [])
        .resolve(edits, in: paragraph, language: .nl, source: .model, oracle: try FakeWordOracle.measured(), confirmer: nil)
    #expect(kept.map(\.original) == ["word"])
}

@Test(arguments: [nil, false] as [Bool?])
private func resolveDropsAnUndecidedEditTheConfirmerDoesNotApprove(_ answer: Bool?) async throws {
    let (paragraph, edits) = wordtAndVoor()
    let confirmer = StubConfirmer(answer)
    let kept = await EditGuard(neverTouch: [])
        .resolve(edits, in: paragraph, language: .nl, source: .model, oracle: try FakeWordOracle.measured(), confirmer: confirmer)
    #expect(kept.map(\.original) == ["word"])
    #expect(await confirmer.asked == ["om"])
}

@Test func resolveKeepsAnUndecidedEditTheConfirmerApproves() async throws {
    let (paragraph, edits) = wordtAndVoor()
    let confirmer = StubConfirmer(true)
    let kept = await EditGuard(neverTouch: [])
        .resolve(edits, in: paragraph, language: .nl, source: .model, oracle: try FakeWordOracle.measured(), confirmer: confirmer)
    #expect(kept.map(\.replacement) == ["wordt", "voor"])
    #expect(await confirmer.asked == ["om"])
}

@Test("Proposals judged together", arguments: resolveTable)
private func resolveRow(_ row: ResolveRow) async throws {
    let oracle = try FakeWordOracle.measured()
    let kept = await EditGuard(neverTouch: [])
        .resolve(row.edits, in: row.paragraph, language: row.language, source: row.source, oracle: oracle, confirmer: nil)
    #expect(kept.map { "\($0.original) → \($0.replacement)" } == row.kept)
    #expect(await oracle.unknownWords.isEmpty)
}

@Test func theGuardKeepsTheTrueFixesAndDropsTheFalseAlarmsOfTheSpikeRun() async throws {
    let outputs: [EvalOutput] = try EvalScorer.loadJSONL(Fixtures.url("out-apple-v3"))
    let oracle = try FakeWordOracle.measured()
    let guardrail = EditGuard(neverTouch: [])
    var trueFixes = 0, falseAlarms = 0
    var droppedTrue: [String] = [], keptFalse: [String] = []
    for row in outputs {
        guard let c = spike[row.id], let revised = row.output?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
        let reference = EvalScorer.keys(c.text, c.ref)
        let proposed = TextDiff.edits(from: c.text, to: revised)
        let kept = Set(await guardrail.resolve(proposed, in: c.text, language: c.lang, source: .model, oracle: oracle, confirmer: nil))
        for edit in proposed {
            let label = "\(c.id): \(edit.original) → \(edit.replacement)"
            if reference.contains(EvalScorer.key(of: edit)) {
                trueFixes += 1
                if !kept.contains(edit) { droppedTrue.append(label) }
            } else {
                falseAlarms += 1
                if kept.contains(edit) { keptFalse.append(label) }
            }
        }
    }
    #expect(droppedTrue.isEmpty, "dropped true fixes: \(droppedTrue)")
    #expect(keptFalse.isEmpty, "kept false alarms: \(keptFalse)")
    #expect((trueFixes, falseAlarms) == (34, 6))
    #expect(await oracle.unknownWords.isEmpty)
}
