import Foundation
import SkaldCore
import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27

private func paragraph(_ text: String) -> Paragraph {
    Paragraph(range: TextRange(location: 0, length: text.utf16.count), text: text)
}

private func flaggedWithAlternatives(_ text: String, _ language: Language, neverTouch: Set<String> = []) async -> [SpellingFlag] {
    await SpellingChecker().flags(in: paragraph(text), language: language, neverTouch: neverTouch)
}

private func flagged(_ text: String, _ language: Language, neverTouch: Set<String> = []) async -> [Edit] {
    await flaggedWithAlternatives(text, language, neverTouch: neverTouch).map(\.edit)
}

private func resolved(_ text: String, _ language: Language) async -> [String] {
    let edits = await flagged(text, language)
    return await EditGuard(neverTouch: [])
        .resolve(edits, in: text, language: language, source: .spelling, oracle: SystemWordOracle(), confirmer: nil)
        .map(\.original)
}

struct SpellingCheckerTests {
    @Test("Dutch leaves only the real typo", .tags(.requiresSystem))
    func dutch() async {
        #expect(await resolved("eigelijk onmiddelijk reviewt Sidekiq-jobs", .nl) == ["onmiddelijk"])
    }

    @Test("French leaves only the real typo", .tags(.requiresSystem))
    func french() async {
        #expect(await resolved("J'ai mergé la branche deja.", .fr) == ["deja"])
    }

    @Test("English accepts both spellings of colour", .tags(.requiresSystem))
    func english() async {
        #expect(await resolved("colour color recieve", .en) == ["recieve"])
    }

    @Test("Each flag carries the first guess as its replacement", .tags(.requiresSystem))
    func firstGuess() async throws {
        let edits = await flagged("We hebben onmiddelijk gebeld.", .nl)
        let edit = try #require(edits.first { $0.original == "onmiddelijk" })
        #expect(edit.replacement == "onmiddellijk")
    }

    @Test("An English flag proposes the British spelling", .tags(.requiresSystem),
          arguments: [("behavour", "behaviour"), ("colur", "colour"), ("organisaton", "organisation"), ("centr", "centre"), ("recieve", "receive")])
    func britishGuess(_ word: String, _ guess: String) async throws {
        let edit = try #require(await flagged("We saw the \(word) today.", .en).first)
        #expect(edit.original == word)
        #expect(edit.replacement == guess)
    }

    @Test("A flag without a guess has an empty replacement", .tags(.requiresSystem))
    func noGuess() async throws {
        let edits = await flagged("De Sidekiq-jobs zijn groen.", .nl)
        let edit = try #require(edits.first { $0.original == "Sidekiq-jobs" })
        #expect(edit.replacement.isEmpty)
    }

    @Test("A flag after an emoji still hits its word in UTF-16 units", .tags(.requiresSystem))
    func offsetsAfterAnEmoji() async throws {
        let text = "👍🏽 I will recieve it."
        let edit = try #require(await flagged(text, .en).first)
        #expect(edit.original == "recieve")
        let found = (text as NSString).substring(with: NSRange(location: edit.range.location, length: edit.range.length))
        #expect(found == "recieve")
    }

    @Test("Never-touch words and phrases are skipped, case-insensitively", .tags(.requiresSystem))
    func neverTouch() async {
        let text = "We keep Qwxzy-prem and Talos here, recieve."
        let all = await flagged(text, .en).map(\.original)
        #expect(all.contains("recieve") && all.contains("Talos"))
        let skipped = await flagged(text, .en, neverTouch: ["qwxzy-prem", "TALOS"]).map(\.original)
        #expect(skipped == ["recieve"])
    }

    @Test("A never-touch word does not protect a longer word that contains it", .tags(.requiresSystem))
    func neverTouchContainment() async {
        let flags = await flagged("Please check the runbok.", .en, neverTouch: ["run"]).map(\.original)
        #expect(flags == ["runbok"])
    }

    @Test("Flags carry offsets within the paragraph, not the field", .tags(.requiresSystem))
    func paragraphRelativeOffsets() async throws {
        let text = "Please recieve it."
        let shifted = Paragraph(range: TextRange(location: 500, length: text.utf16.count), text: text)
        let edit = try #require(await SpellingChecker().flags(in: shifted, language: .en, neverTouch: []).first).edit
        #expect(edit.range == TextRange(location: 7, length: 7))
    }

    @Test("A flag's other guesses differ from its edit and from each other and share its range", .tags(.requiresSystem),
          arguments: [("Het verjaardg was leuk.", "verjaardg", Language.nl), ("Il est arrivé deja hier.", "deja", .fr), ("Please recieve it.", "recieve", .en)])
    func alternatives(_ text: String, _ word: String, _ language: Language) async throws {
        let flag = try #require(await flaggedWithAlternatives(text, language).first { $0.edit.original == word })
        let replacements = flag.alternatives.map(\.replacement)
        #expect(!replacements.isEmpty)
        #expect(!replacements.contains(flag.edit.replacement))
        #expect(Set(replacements).count == replacements.count)
        #expect(flag.alternatives.allSatisfy { $0.range == flag.edit.range })
    }

    @Test("Several checkers can run side by side and be released", .tags(.requiresSystem))
    func severalCheckers() async {
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask { await flagged("recieve", .en).count }
            }
            for await count in group { #expect(count == 1) }
        }
    }
}
