import SkaldCore
import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27
@testable import SkaldCore

@Test("The spec's outcome table, with the system's word facts", .tags(.requiresSystem), arguments: outcomeTable + measuredGuesses)
private func outcome(_ row: Row) async throws {
    let found = TextDiff.edits(from: row.paragraph, to: row.revised)
    try #require(found.count == 1)
    let facts = await SystemWordOracle().facts(for: EditGuard.words(in: found), language: row.language)
    let verdict = EditGuard(neverTouch: row.neverTouch)
        .verdict(for: found[0], in: row.paragraph, language: row.language, source: row.source, facts: facts)
    #expect(verdict == row.expected)
}
