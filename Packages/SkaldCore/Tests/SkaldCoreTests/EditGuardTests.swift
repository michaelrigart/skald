import Foundation
import Testing
@testable import SkaldCore

private let spike: [String: EvalCase] = {
    let cases: [EvalCase] = try! EvalScorer.loadJSONL(Fixtures.url("testset"))
    return Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
}()

private func swap(_ text: String, _ old: String, _ new: String) -> String {
    let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: old) + "(?!\\w)"
    let regex = try! NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))!
    return ns.replacingCharacters(in: match.range, with: new)
}

private struct Row: Sendable, CustomTestStringConvertible {
    let name: String
    let language: Language
    let paragraph: String
    let revised: String
    let source: IssueSource
    let neverTouch: Set<String>
    let expected: GuardVerdict
    var testDescription: String { name }

    init(_ name: String, _ language: Language, _ paragraph: String, _ revised: String, _ expected: GuardVerdict,
         source: IssueSource = .model, neverTouch: Set<String> = []) {
        self.name = name
        self.language = language
        self.paragraph = paragraph
        self.revised = revised
        self.source = source
        self.neverTouch = neverTouch
        self.expected = expected
    }

    init(_ id: String, _ old: String, _ new: String, _ expected: GuardVerdict,
         source: IssueSource = .model, neverTouch: Set<String> = []) {
        let c = spike[id]!
        self.init("\(source == .spelling ? "spelling " : "")\(old) → \(new)", c.lang, c.text, swap(c.text, old, new), expected,
                  source: source, neverTouch: neverTouch)
    }
}

private let outcomeTable: [Row] = [
    Row("en1", "went", "gone", .keep),
    Row("nl6", "Hun", "Zij", .keep),
    Row("nl3", "als", "dan", .keep),
    Row("fr3", "est", "sont", .keep),
    Row("nl1", "word", "wordt", .keep),
    Row("fr8", "regarderais", "regarderai", .keep),
    Row("nl2", "gedownloaded", "gedownload", .keep),
    Row("en3", "friday", "Friday", .keep),
    Row("nl5", "voorvallen", "voorkomen", .undecided),
    Row("fr3", "passent", "se déroulent", .drop(.replacement)),
    Row("frc2", "proprement", "correctement", .drop(.replacement)),
    Row("nlc1", "gemerged", "gemerkt", .drop(.borrowedWord)),
    Row("frc2", "mergé", "fusionné", .drop(.borrowedWord)),
    Row("fr8", "tiens", "tiendrai", .drop(.tenseChange)),
    Row("A final period", .en, spike["enc4"]!.text, spike["enc4"]!.text + ".", .drop(.addedFormality)),
    Row("nlc3", "Sidekiq-jobs", "", .drop(.nameNumberURLOrCode), source: .spelling),
    Row("enc1", "Talos", "Tacos", .drop(.nameNumberURLOrCode), source: .spelling),
    Row("en3", "Pieter", "Peter", .drop(.nameNumberURLOrCode), source: .spelling),
    Row("en2", "run", "runs", .drop(.neverTouch), neverTouch: ["run"]),
    Row("en2", "run", "runs", .drop(.neverTouch), neverTouch: ["Runs"]),
    Row("nlc4", "14e", "15e", .drop(.nameNumberURLOrCode)),
    Row("A URL", .en, "Docs are at https://example.com/runbok today.", "Docs are at https://example.com/runbook today.",
        .drop(.nameNumberURLOrCode)),
    Row("A www address", .en, "Docs are at www.example.com/runbok today.", "Docs are at www.example.com/runbook today.",
        .drop(.nameNumberURLOrCode)),
    Row("Backticked code", .en, "Run `deploy_app` first.", "Run `deploy_apps` first.", .drop(.nameNumberURLOrCode)),
    Row("A snake_case token", .en, "Run deploy_app first.", "Run deploy_apps first.", .drop(.nameNumberURLOrCode)),
    Row("A camelCase token", .en, "Call getUserName first.", "Call getUsername first.", .drop(.nameNumberURLOrCode)),
    Row("A :: path", .en, "Call foo::runbok first.", "Call foo::runbook first.", .drop(.nameNumberURLOrCode)),
    Row("A spelling flag without a guess", .nl, spike["nl4"]!.text,
        spike["nl4"]!.text.replacingOccurrences(of: "onmiddelijk ", with: ""), .drop(.noSuggestion), source: .spelling),
    Row("enc4", "ping", "Ping", .drop(.addedFormality)),
    Row("A capital in a paragraph that capitalises", .en, "Thanks for the update. we will ship it on monday.",
        "Thanks for the update. We will ship it on monday.", .keep),
    Row("A name capitalised elsewhere", .en, "Thanks to Pieter for the review. I will ask pieter again.",
        "Thanks to Pieter for the review. I will ask Pieter again.", .keep),
    Row("A capital on an unknown word", .en, "I will visit paris again.", "I will visit Paris again.", .undecided),
    Row("A question mark ending an unpunctuated last sentence", .en, "Thanks for the fix. Can you deploy it",
        "Thanks for the fix. Can you deploy it?", .keep),
    Row("A period ending an unpunctuated last sentence", .en, "We shipped it. The logs look fine",
        "We shipped it. The logs look fine.", .keep),
    Row("A cognate in the plural", .fr, "Les nouvelles version sont prêtes", "Les nouvelles versions sont prêtes", .keep),
    Row("A cognate in the plural, Dutch", .nl, "Er zijn drie bug gevonden.", "Er zijn drie bugs gevonden.", .keep),
    Row("A cognate with its accent", .fr, "Cette operation est lente.", "Cette opération est lente.", .keep),
    Row("A never-touch phrase with a dot", .en, "We run Node.js in production.", "We run Node.JS in production.",
        .drop(.neverTouch), neverTouch: ["Node.js"]),
    Row("A hyphenated never-touch phrase", .en, "We keep it on-prem for now.", "We keep it on-premise for now.",
        .drop(.neverTouch), neverTouch: ["on-prem"]),
    Row("en2", "it's", "its", .keep, neverTouch: ["run"]),
    Row("A French weekday is lowercase", .fr, "On se voit lundi.", "On se voit Lundi.", .drop(.addedFormality)),
    Row("A Dutch weekday is lowercase", .nl, "Op maandag", "Op Maandag", .drop(.addedFormality)),
    Row("A Dutch adverb is not a function word", .nl, "Het werkt wel.", "Het werkt niet.", .undecided),
    Row("An English adverb is not a function word", .en, "I also checked the logs.", "I just checked the logs.", .drop(.replacement)),
    Row("A French adverb is not a function word", .fr, "Je ne le fais plus.", "Je ne le fais jamais.", .drop(.borrowedWord)),
    Row("A preposition swap is not a function-word fix", .nl, "Ik laat je iets weten tegen vrijdag.",
        "Ik laat je iets weten voor vrijdag.", .undecided),
    Row("A preposition replaced by a verb", .en, "I could of fixed it.", "I could have fixed it.", .undecided),
    Row("A preposition replaced by a preposition", .en, "I am afraid from dogs.", "I am afraid of dogs.", .undecided),
    Row("A preposition that differs by an accent", .fr, "Il va a Paris", "Il va à Paris", .keep),
    Row("A preposition with its final letter doubled", .en, "it looks of", "it looks off", .keep),
    Row("A near-homophone preposition", .en, "It is in the repo.", "It is on the repo.", .undecided),
    Row("A near-homophone Dutch preposition", .nl, "Het werkt voor vrijdag.", "Het werkt door vrijdag.", .undecided),
    Row("A French preposition swap", .fr, "Je travaille dans France.", "Je travaille en France.", .undecided),
    Row("A fixed expression: suppose to", .en, "I'm suppose to deploy.", "I'm supposed to deploy.", .keep),
    Row("A fixed expression: use to", .en, "I use to work there.", "I used to work there.", .keep),
    Row("An ambiguous contraction", .en, "I'd walk there.", "I'd walked there.", .undecided),
    Row("A final period after a sentence starting with I", .en, "lol. I'll ship it", "lol. I'll ship it.", .drop(.addedFormality)),
    Row("A tense change in English", .en, "I walk to the office.", "I walked to the office.", .drop(.tenseChange)),
    Row("A participle after an auxiliary in English", .en, "I have walk home.", "I have walked home.", .keep),
    Row("A participle after a negated auxiliary", .en, "I haven't went there.", "I haven't gone there.", .keep),
    Row("A participle after a contracted auxiliary", .en, "She's went home.", "She's gone home.", .keep),
    Row("A first word after a bullet starts a sentence", .en, "- Fixd the bug", "- Fixed the bug", .keep, source: .spelling),
    Row("en1", "Hi Sarah", "Hi, Sarah", .keep),
    Row("en3", "the the", "the", .keep),
    Row("en6", "recieve", "receive", .keep),
    Row("en2", "it's", "its", .keep),
    Row("en7", "Lets", "Let's", .keep),
    Row("en2", "run", "runs", .keep),
    Row("nl5", "gebeurt", "gebeurd", .keep),
    Row("nl3", "eigelijk", "eigenlijk", .keep),
    Row("fr6", "deja", "déjà", .keep),
    Row("fr6", "lente", "lentes", .keep),
    Row("fr5", "envoyé", "envoyée", .keep),
    Row("fr7", "ces", "c'est", .keep),
]

private let measuredGuesses: [Row] =
    ["reviews", "review", "reviert", "Previewt"].map { Row("nlc4", "reviewt", $0, .drop(.borrowedWord), source: .spelling) }
    + ["Serge", "marge", "Hergé", "merle", "margé"].map { Row("frc2", "mergé", $0, .drop(.borrowedWord), source: .spelling) }

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
    #expect(guardrail.verdict(for: found[0], in: paragraph, language: .nl, source: .model, facts: WordFacts()) == .undecided)
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

private func gebeurdAndVoorkomen() -> (paragraph: String, edits: [Edit]) {
    let c = spike["nl5"]!
    return (c.text, TextDiff.edits(from: c.text, to: swap(c.ref, "voorvallen", "voorkomen")))
}

@Test func resolveDropsAnUndecidedEditWhenThereIsNoConfirmer() async throws {
    let (paragraph, edits) = gebeurdAndVoorkomen()
    let kept = await EditGuard(neverTouch: [])
        .resolve(edits, in: paragraph, language: .nl, source: .model, oracle: try FakeWordOracle.measured(), confirmer: nil)
    #expect(kept.map(\.original) == ["gebeurt"])
}

@Test(arguments: [nil, false] as [Bool?])
private func resolveDropsAnUndecidedEditTheConfirmerDoesNotApprove(_ answer: Bool?) async throws {
    let (paragraph, edits) = gebeurdAndVoorkomen()
    let confirmer = StubConfirmer(answer)
    let kept = await EditGuard(neverTouch: [])
        .resolve(edits, in: paragraph, language: .nl, source: .model, oracle: try FakeWordOracle.measured(), confirmer: confirmer)
    #expect(kept.map(\.original) == ["gebeurt"])
    #expect(await confirmer.asked == ["voorvallen"])
}

@Test func resolveKeepsAnUndecidedEditTheConfirmerApproves() async throws {
    let (paragraph, edits) = gebeurdAndVoorkomen()
    let confirmer = StubConfirmer(true)
    let kept = await EditGuard(neverTouch: [])
        .resolve(edits, in: paragraph, language: .nl, source: .model, oracle: try FakeWordOracle.measured(), confirmer: confirmer)
    #expect(kept.map(\.replacement) == ["gebeurd", "voorkomen"])
    #expect(await confirmer.asked == ["voorvallen"])
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
