import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27
@testable import SkaldCore

private func needsFrenchLemmas(_ row: Row) -> Bool {
    row.language == .fr && row.expected == .drop(.tenseChange)
}

@Test("The spec's outcome table, with the system's word facts", .tags(.requiresSystem),
      arguments: (outcomeTable + measuredGuesses).filter { !needsFrenchLemmas($0) })
private func outcome(_ row: Row) async throws {
    try await expectOutcome(row)
}

@Test("A French tense change needs the system's lemmas", .tags(.requiresSystem), .requiresFrenchTagger,
      arguments: (outcomeTable + measuredGuesses).filter(needsFrenchLemmas))
private func frenchOutcome(_ row: Row) async throws {
    try await expectOutcome(row)
}

private func expectOutcome(_ row: Row) async throws {
    let found = TextDiff.edits(from: row.paragraph, to: row.revised)
    try #require(found.count == 1)
    let facts = await SystemWordOracle().facts(for: EditGuard.words(in: found), language: row.language)
    let verdict = EditGuard(neverTouch: row.neverTouch)
        .verdict(for: found[0], in: row.paragraph, language: row.language, source: row.source, facts: facts)
    #expect(verdict == row.expected)
}

@Test("Proposals judged together, with the system's word facts", .tags(.requiresSystem), arguments: resolveTable)
private func resolveRow(_ row: ResolveRow) async {
    let kept = await EditGuard(neverTouch: [])
        .resolve(row.edits, in: row.paragraph, language: row.language, source: row.source, oracle: SystemWordOracle(), confirmer: nil)
    #expect(kept.map { "\($0.original) → \($0.replacement)" } == row.kept)
}

@Test("The spelling flag on behavour proposes behaviour, and the guard keeps it", .tags(.requiresSystem))
private func britishGuessIsKept() async {
    let text = "His behavour was odd during the call."
    let flags = await SpellingChecker().flags(in: Paragraph(range: TextRange(location: 0, length: text.utf16.count), text: text),
                                              language: .en, neverTouch: [])
    let kept = await EditGuard(neverTouch: [])
        .resolve(flags, in: text, language: .en, source: .spelling, oracle: SystemWordOracle(), confirmer: nil)
    #expect(kept.map { "\($0.original) → \($0.replacement)" } == ["behavour → behaviour"])
}
