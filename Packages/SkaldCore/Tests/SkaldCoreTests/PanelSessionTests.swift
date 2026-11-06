import Foundation
import Testing
@testable import SkaldCore
import SkaldCoreTestSupport
import struct SkaldCore.TextRange

private let field = FieldID(app: "com.example.notes", token: "1")
private let otherField = FieldID(app: "com.example.notes", token: "2")
private let studio = StudioEndpoint(api: .ollama, baseURL: "http://studio.local:11434", model: "qwen")

private let flew = "We flew to teh office in paris yesterday"
private let dutch = "Ik heb het rapport gisteren gedownloaded."

private func makeSettings(dutchModel: Bool = true, studio configured: Bool = false, panelDefault: EngineKind = .thisMac) -> Settings {
    var settings = Settings()
    for language in Language.allCases {
        settings.typingChecks[language] = true
        settings.modelChecks[language] = true
    }
    settings.modelChecks[.nl] = dutchModel
    if configured { settings.studio = studio }
    settings.panelDefaultEngine = panelDefault
    return settings
}

private func makeRouter(_ settings: Settings, apple: UnavailableReason? = nil, key: Bool = true) -> EngineRouter {
    EngineRouter(settings: settings, appleAvailability: apple, thermalPaused: false, claudeKeyPresent: key)
}

private func misspelled(_ words: [String: [String]]) -> FakeWordOracle {
    FakeWordOracle(dictionary: words.mapValues { list in
        Dictionary(uniqueKeysWithValues: list.map { ($0, FakeWordOracle.Entry(misspelled: true, english: false, stem: nil, lemma: nil, function: nil)) })
    })
}

/// Approves every edit it is asked about, and runs `onAsk` first.
private actor ApprovingConfirmer: EditConfirming {
    private(set) var asked: [String] = []
    private let onAsk: @Sendable () async -> Void

    init(onAsk: @escaping @Sendable () async -> Void = {}) {
        self.onAsk = onAsk
    }

    func confirm(_ edit: Edit, in paragraph: String, language: Language) async -> Bool? {
        asked.append(edit.original)
        await onAsk()
        return true
    }
}

private struct Rig {
    let thisMac: FakeEngine
    let studio: FakeEngine
    let claude: FakeEngine
    let access = FakeTextAccess()
    let router: LiveRouter
    let session: PanelSession

    init(
        text: String,
        capture: SelectionCapture? = nil,
        settings: Settings = makeSettings(),
        engineRouter: EngineRouter? = nil,
        thisMac: FakeEngine = .correcting(["teh": "the"]),
        studio: FakeEngine = .correcting([:]),
        claude: FakeEngine = .correcting(["teh": "the"]),
        detector: FakeLanguageDetector = FakeLanguageDetector(),
        oracle: any WordOracle = misspelled(["en": ["teh"]]),
        confirmer: (any EditConfirming)? = nil,
        router live: LiveRouter? = nil,
        fieldLanguage: Language? = nil
    ) {
        self.thisMac = thisMac
        self.studio = studio
        self.claude = claude
        let router = live ?? LiveRouter(engineRouter ?? makeRouter(settings))
        self.router = router
        session = PanelSession(
            capture: capture,
            text: text,
            detector: detector,
            editGuard: EditGuard(neverTouch: Set(settings.neverTouch)),
            oracle: oracle,
            confirmer: confirmer,
            engines: [.thisMac: thisMac, .macStudio: studio, .claude: claude],
            router: router,
            access: access,
            fieldLanguage: fieldLanguage
        )
    }
}

// MARK: Fix

@Test func aMixedSelectionIsFixedPerParagraphInItsOwnLanguageAndKeepsItsBreaks() async throws {
    let text = flew + "\n\n" + dutch + "\n"
    let rig = Rig(text: text)
    let result = await rig.session.run(.fix, on: nil)

    let requests = await rig.thisMac.requests
    #expect(requests.map(\.action) == [.fix, .fix])
    #expect(requests.map(\.language) == [.en, .nl])
    #expect(requests.map(\.text) == [flew, dutch])
    let revised = "We flew to the office in paris yesterday\n\n" + dutch + "\n"
    #expect(result == .revised(text: revised, edits: TextDiff.edits(from: text, to: revised), engine: .thisMac))
}

@Test func fixSplitsALongParagraphIntoChunksOfAtMost1200Units() async {
    let sentence = "This sentence has teh word and " + String(repeating: "more plain words ", count: 30) + "end. "
    let paragraph = String(repeating: sentence, count: 3).trimmingCharacters(in: .whitespaces)
    let rig = Rig(text: paragraph)
    let result = await rig.session.run(.fix, on: nil)

    let texts = await rig.thisMac.texts
    #expect(texts.count > 1)
    #expect(texts.allSatisfy { $0.utf16.count <= 1200 })
    #expect(texts.joined() == paragraph)
    guard case .revised(let revised, _, _) = result else { Testing.Issue.record("not revised: \(result)"); return }
    #expect(revised == paragraph.replacingOccurrences(of: "teh", with: "the"))
}

@Test func aFinalPunctuationFixAtAChunkBoundaryKeepsTheSpaceBeforeTheNextChunk() async {
    let first = "The first part needs an " + String(repeating: "more plain words here and ", count: 38) + "update!!"
    let paragraph = first + " " + "The second part follows " + String(repeating: "with plain words here and ", count: 38) + "done."
    let rig = Rig(text: paragraph, thisMac: .trimmingAndFixingDoubleBang, oracle: misspelled([:]))
    let result = await rig.session.run(.fix, on: nil)

    #expect(await rig.thisMac.texts.count == 2)
    guard case .revised(let revised, _, _) = result else { Testing.Issue.record("not revised: \(result)"); return }
    #expect(revised == paragraph.replacingOccurrences(of: "update!!", with: "update!"))
}

@Test func fixDropsAWholeAnswerThatChangesTooMuch() async {
    let engine = FakeEngine { _, _ in .success("Our team travelled by plane to the Paris office the day before") }
    let rig = Rig(text: flew, thisMac: engine)
    let result = await rig.session.run(.fix, on: nil)
    #expect(result == .revised(text: flew, edits: [], engine: .thisMac))
}

private func backUp() -> (text: String, answer: String) {
    let c = spike["nl1"]!
    return (c.text, swap(c.ref, "om", "voor"))
}

private func dutchRig(
    dutchModel: Bool = true, text: String, answer: String = backUp().answer, confirmer: ApprovingConfirmer, router: LiveRouter? = nil
) throws -> Rig {
    Rig(
        text: text,
        settings: makeSettings(dutchModel: dutchModel),
        thisMac: FakeEngine { _, _ in .success(answer) },
        detector: FakeLanguageDetector(markers: [("Hallo Jan", .nl), ("Ik heb", .nl)]),
        oracle: try FakeWordOracle.measured(),
        confirmer: confirmer,
        router: router
    )
}

@Test func anUndecidedDutchEditIsKeptWhenTheGatedConfirmerApproves() async throws {
    let (text, answer) = backUp()
    let confirmer = ApprovingConfirmer()
    let rig = try dutchRig(text: text, confirmer: confirmer)
    let result = await rig.session.run(.fix, on: nil)
    #expect(await confirmer.asked == ["om"])
    #expect(result == .revised(text: answer, edits: TextDiff.edits(from: text, to: answer), engine: .thisMac))
}

@Test func anUndecidedDutchEditIsDroppedWhenTheRouterSaysSpellingOnly() async throws {
    let (text, _) = backUp()
    let confirmer = ApprovingConfirmer()
    let rig = try dutchRig(dutchModel: false, text: text, confirmer: confirmer)
    let result = await rig.session.run(.fix, on: nil)
    let fixed = spike["nl1"]!.ref
    #expect(await confirmer.asked.isEmpty)
    #expect(result == .revised(text: fixed, edits: TextDiff.edits(from: text, to: fixed), engine: .thisMac))
}

/// Both undecided edits are in one paragraph, so one chunk: a gate read once per chunk would ask about both.
@Test func theGateIsReadOnEveryConfirmationSoASpellingOnlyRouterSetBetweenTwoStopsTheSecond() async throws {
    let (paragraph, answer) = backUp()
    let text = paragraph + " " + paragraph
    let live = LiveRouter(makeRouter(makeSettings()))
    let spellingOnly = makeRouter(makeSettings(dutchModel: false))
    let confirmer = ApprovingConfirmer { await live.set(spellingOnly) }
    let rig = try dutchRig(text: text, answer: answer + " " + answer, confirmer: confirmer, router: live)
    let result = await rig.session.run(.fix, on: nil)

    #expect(await rig.thisMac.requests.count == 1)
    #expect(await confirmer.asked == ["om"])
    let revised = answer + " " + spike["nl1"]!.ref
    #expect(result == .revised(text: revised, edits: TextDiff.edits(from: text, to: revised), engine: .thisMac))
}

// MARK: Languages

@Test func aSelectionWithNoLanguageToDetectOrInheritAsksForOneAndCallsNoEngine() async {
    let rig = Rig(text: "morgen")
    #expect(await rig.session.needsLanguage())
    #expect(await rig.session.run(.fix, on: nil) == .needsLanguage)
    #expect(await rig.session.run(.shorter, on: nil) == .needsLanguage)
    #expect(await rig.thisMac.requests.isEmpty)
}

@Test func theUsersPickIsTheLanguageOfAnUndetectableSelection() async {
    let rig = Rig(text: "morgen")
    await rig.session.choose(.nl)
    #expect(await !rig.session.needsLanguage())
    _ = await rig.session.run(.shorter, on: nil)
    #expect(await rig.thisMac.requests.map(\.language) == [.nl])
}

@Test func aShortSelectionInheritsTheFieldsLastConfidentLanguage() async {
    let rig = Rig(text: "morgen", fieldLanguage: .nl)
    #expect(await !rig.session.needsLanguage())
    _ = await rig.session.run(.fix, on: nil)
    #expect(await rig.thisMac.requests.map(\.language) == [.nl])
}

// MARK: Rewrites

@Test func aSameLanguageRewriteSendsTheWholeSelectionAsOneRequest() async {
    let text = "The first paragraph is long enough.\n\nThe second paragraph is long enough too.\n"
    let engine = FakeEngine { _, _ in .success("Both paragraphs, shorter.") }
    let rig = Rig(text: text, thisMac: engine)
    let result = await rig.session.run(.shorter, on: nil)

    let requests = await engine.requests
    #expect(requests.map(\.action) == [.shorter])
    #expect(requests.map(\.language) == [.en])
    #expect(requests.map(\.text) == ["The first paragraph is long enough.\n\nThe second paragraph is long enough too."])
    let revised = "Both paragraphs, shorter.\n"
    #expect(result == .revised(text: revised, edits: TextDiff.edits(from: text, to: revised), engine: .thisMac))
}

@Test func aMixedLanguageRewriteRunsPerParagraphInEachLanguage() async {
    let text = flew + "\n\n" + dutch
    let engine = FakeEngine { request, _ in .success(request.language == .en ? "We flew in yesterday." : "Ik heb het gedownload.") }
    let rig = Rig(text: text, thisMac: engine)
    let result = await rig.session.run(.friendlier, on: nil)

    let requests = await engine.requests
    #expect(requests.map(\.action) == [.friendlier, .friendlier])
    #expect(requests.map(\.language) == [.en, .nl])
    #expect(requests.map(\.text) == [flew, dutch])
    let revised = "We flew in yesterday.\n\nIk heb het gedownload."
    #expect(result == .revised(text: revised, edits: TextDiff.edits(from: text, to: revised), engine: .thisMac))
}

// MARK: Routing

@Test func anUnreachableStudioReturnsItsAlternatives() async {
    let unreachable = FakeEngine { _, _ in .failure(.unavailable(.studioUnreachable)) }
    let rig = Rig(text: flew, settings: makeSettings(studio: true), studio: unreachable)
    let result = await rig.session.run(.shorter, on: .macStudio)
    #expect(await unreachable.requests.count == 1)
    #expect(result == .unavailable(.macStudio, .studioUnreachable, alternatives: [.thisMac, .claude]))
}

@Test func anEngineTheRouterRulesOutIsNeverCalled() async {
    let rig = Rig(text: flew, engineRouter: makeRouter(makeSettings(), key: false))
    let result = await rig.session.run(.fix, on: .claude)
    #expect(result == .unavailable(.claude, .claudeKeyMissing, alternatives: [.thisMac]))
    #expect(await rig.claude.requests.isEmpty)
}

@Test func claudeIsNeverCalledUnlessChosenOrTheDefault() async {
    let rig = Rig(text: flew)
    _ = await rig.session.run(.fix, on: nil)
    _ = await rig.session.run(.shorter, on: .thisMac)
    #expect(await rig.claude.requests.isEmpty)
    #expect(await rig.thisMac.requests.count == 2)

    let chosen = await rig.session.run(.fix, on: .claude)
    #expect(await rig.claude.requests.count == 1)
    guard case .revised(_, _, let engine) = chosen else { Testing.Issue.record("not revised: \(chosen)"); return }
    #expect(engine == .claude)

    let byDefault = Rig(text: flew, settings: makeSettings(panelDefault: .claude))
    _ = await byDefault.session.run(.fix, on: nil)
    #expect(await byDefault.claude.requests.count == 1)
    #expect(await byDefault.thisMac.requests.isEmpty)
}

@Test func routingIsReadWhenEachRunStarts() async {
    let rig = Rig(text: flew)
    _ = await rig.session.run(.fix, on: nil)
    await rig.router.set(makeRouter(makeSettings(panelDefault: .claude)))
    _ = await rig.session.run(.fix, on: nil)
    #expect(await rig.thisMac.requests.count == 1)
    #expect(await rig.claude.requests.count == 1)
}

@Test func anEngineFailureIsReturned() async {
    let refusing = FakeEngine { _, _ in .failure(.refused) }
    let rig = Rig(text: flew, thisMac: refusing)
    #expect(await rig.session.run(.clearer, on: nil) == .failed(.refused))
}

@Test func aNewerRunSupersedesAnOlderOne() async {
    let engine = FakeEngine(gated: true) { _, index in .success(index == 0 ? "The first answer here." : "The second answer here.") }
    let rig = Rig(text: flew, thisMac: engine)
    let first = Task { await rig.session.run(.shorter, on: nil) }
    await engine.waitForRequests(1)
    let second = Task { await rig.session.run(.clearer, on: nil) }
    await engine.waitForRequests(2)
    await engine.release(1)
    let newer = await second.value
    await engine.release(0)
    let older = await first.value

    #expect(older == .failed(.cancelled))
    #expect(await engine.cancelled == [0])
    let revised = "The second answer here."
    #expect(newer == .revised(text: revised, edits: TextDiff.edits(from: flew, to: revised), engine: .thisMac))
}

// MARK: Replace

private let paragraphText = "We flew to teh office in paris yesterday and back."
private let context = ExpectedText(range: TextRange(location: 10, length: paragraphText.utf16.count), text: paragraphText)

@Test func replacePassesTheCapturedSelectionAndContext() async {
    let capture = SelectionCapture(field: field, selection: TextRange(location: 21, length: 3), selectedText: "teh", context: context)
    let rig = Rig(text: "teh", capture: capture)
    #expect(await rig.session.replace(with: "the") == .replaced)
    #expect(await rig.access.replacements == [.init(range: capture.selection, expected: context, text: "the", field: field)])
}

@Test(arguments: [ReplaceOutcome.refusedChanged, .refusedOtherField, .unconfirmed])
func aRefusalFromTextAccessIsReturned(_ outcome: ReplaceOutcome) async {
    let capture = SelectionCapture(field: otherField, selection: context.range, selectedText: paragraphText, context: context)
    let rig = Rig(text: paragraphText, capture: capture)
    await rig.access.answerReplacements(with: outcome)
    #expect(await rig.session.replace(with: "Changed.") == outcome)
    #expect(await rig.access.replacements.map(\.field) == [otherField])
}

@Test func anEmptyReplacementFailsAndWritesNothing() async {
    let capture = SelectionCapture(field: field, selection: TextRange(location: 21, length: 3), selectedText: "teh", context: context)
    let rig = Rig(text: "teh", capture: capture)
    #expect(await rig.session.replace(with: "") == .failed)
    #expect(await rig.access.replacements.isEmpty)
}

@Test func withoutACaptureReplaceIsUnsupportedAndWritesNothing() async {
    let rig = Rig(text: flew)
    #expect(await rig.session.replace(with: "We flew") == .unsupported)
    #expect(await rig.access.replacements.isEmpty)
}
