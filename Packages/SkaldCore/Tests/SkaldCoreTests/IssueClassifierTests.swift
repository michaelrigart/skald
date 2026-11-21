import Foundation
import SkaldCoreTestSupport
import Testing
@testable import SkaldCore

private func kind(
    _ text: String,
    _ revised: String,
    _ language: Language = .en,
    source: IssueSource = .model,
    misspelled: Set<String> = [],
    lemmas: [String: String] = [:]
) -> IssueKind {
    let edit = TextDiff.edits(from: text, to: revised)[0]
    return IssueClassifier.kind(of: edit, in: text, language: language, source: source, facts: WordFacts(misspelled: misspelled, lemmas: lemmas))
}

@Test func kindsHaveTheirCategoryTitleAndHeadline() {
    #expect(IssueKind.allCases.map(\.category) == [.spelling, .spelling, .spelling, .punctuation, .grammar, .grammar, .grammar])
    #expect(IssueKind.allCases.map(\.title) == ["Spelling", "Capital letter", "Accent", "Punctuation", "Grammar", "Repeated word", "Verb form"])
    #expect(IssueKind.allCases.filter(\.isHideable) == [.capital, .accent, .punctuation, .repeatedWord, .verbForm])
    #expect(IssueKind.verbForm.headline == "Grammar · Verb form")
    #expect(IssueKind.accent.headline == "Spelling · Accent")
    #expect(IssueKind.grammar.headline == "Grammar" && IssueKind.spelling.headline == "Spelling" && IssueKind.punctuation.headline == "Punctuation")
}

@Test func categoriesHaveTitles() {
    #expect(IssueCategory.allCases.map(\.title) == ["Spelling", "Punctuation", "Grammar"])
}

@Test func anEditIsClassifiedByWhatItChanges() {
    #expect(kind("We shipped it. The logs look fine", "We shipped it. The logs look fine.") == .punctuation)
    #expect(kind("Thanks all good.", "Thanks, all good.") == .punctuation)
    #expect(kind("We meet on friday.", "We meet on Friday.") == .capital)
    #expect(kind("Cette operation est lente.", "Cette opération est lente.", .fr) == .accent)
    #expect(kind("cette Operation est lente.", "cette opération est lente.", .fr) == .accent)
    #expect(kind("I saw teh logs.", "I saw the logs.", source: .spelling) == .spelling)
    #expect(kind("I saw teh logs.", "I saw the logs.", misspelled: ["teh"]) == .spelling)
    #expect(kind("See you you tomorrow.", "See you tomorrow.") == .repeatedWord)
    #expect(kind("Het word morgen uitgerold.", "Het wordt morgen uitgerold.", .nl) == .verbForm)
    #expect(kind("Het is gebeurt.", "Het is gebeurd.", .nl) == .verbForm)
    #expect(kind("It word fine.", "It wordt fine.") == .grammar)                 // English: no d/t rule
    #expect(kind("Tout les serveurs sont à jour", "Tous les serveurs sont à jour", .fr) == .grammar)
    #expect(kind("I has it.", "I have it.") == .grammar)
    #expect(kind("See you soon tomorrow.", "See you tomorrow.") == .grammar)     // a deleted word that isn't repeated
    #expect(kind("Hij at het.", "Hij ad het.", .nl) == .grammar)                 // one letter left after the cut
    #expect(kind("Het is hart.", "Het is hard.", .nl, lemmas: ["hart": "hart", "hard": "hard"]) == .grammar)   // not one verb
    #expect(kind("Het word morgen.", "Het wordt morgen.", .nl, lemmas: ["word": "worden", "wordt": "worden"]) == .verbForm)
    #expect(kind("I didn do it.", "I did do it.", misspelled: ["didn"]) == .grammar)   // a misspelled function word, as the guard reads it
}

@Test func theFirstMatchingRuleWins() {
    #expect(kind("We meet on friday.", "We meet on Friday.", source: .spelling, misspelled: ["friday"]) == .capital)
    #expect(kind("Il va a Paris", "Il va à Paris", .fr, source: .spelling) == .accent)
    #expect(kind("See you youu tomorrow.", "See you you tomorrow.", misspelled: ["youu"]) == .spelling)
    #expect(kind("Call getUserName first.", "Call getUsername first.", misspelled: ["getusername"]) == .capital)
}

@Test func aRepeatedWordIsComparedIgnoringCaseWithEitherNeighbour() {
    #expect(kind("The the logs look fine.", "The logs look fine.") == .repeatedWord)
    #expect(kind("The The logs look fine.", "The logs look fine.") == .repeatedWord)
    #expect(kind("Ship it it.", "Ship it.") == .repeatedWord)
}

@Test("Every row of the outcome table has its kind", arguments: outcomeTable + measuredGuesses)
private func everyRowOfTheOutcomeTableHasItsKind(_ row: Row) async throws {
    let found = TextDiff.edits(from: row.paragraph, to: row.revised)
    try #require(found.count == 1)
    let facts = try await FakeWordOracle.measured().facts(for: EditGuard.words(in: found), language: row.language)
    #expect(IssueClassifier.kind(of: found[0], in: row.paragraph, language: row.language, source: row.source, facts: facts) == row.kind)
}
