import Foundation
import Testing
@testable import SkaldCore
import SkaldCoreTestSupport
import struct SkaldCore.Issue
import struct SkaldCore.TextRange

private let fieldA = FieldID(app: "com.example.mail", token: "a")
private let fieldB = FieldID(app: "com.example.mail", token: "b")
private let pause = Duration.milliseconds(700)

private let flew = "We flew to teh office in paris yesterday"
private let talos = "Talos is down again since this morning"

private func makeSettings(typing: Bool = true, model: Bool = true, neverTouch: [String] = []) -> Settings {
    var settings = Settings()
    settings.typingChecks = [.en: typing, .nl: typing, .fr: typing]
    settings.modelChecks = [.en: model, .nl: model, .fr: model]
    neverTouch.forEach { settings.addNeverTouch($0) }
    return settings
}

private func engineRouter(_ settings: Settings, apple: UnavailableReason? = nil) -> EngineRouter {
    EngineRouter(settings: settings, appleAvailability: apple, thermalPaused: false, claudeKeyPresent: false)
}

/// About 1,000 UTF-16 units ending a sentence, so two of them never share a 1,200-unit chunk.
private func sentence(_ name: String) -> String {
    "The \(name) part has teh fix and " + String(repeating: "more plain words here and ", count: 38) + "done."
}

private func chunkTexts(_ text: String) -> [String] {
    Paragraphs.chunks(Paragraph(range: TextRange(location: 0, length: text.utf16.count), text: text)).map(\.text)
}

/// Lines of an earlier thread, at least `units` UTF-16 units long, ending with a line break.
private func thread(_ units: Int) -> String {
    let line = "Earlier message line in the thread.\n"
    return String(repeating: line, count: units / line.utf16.count + 1)
}

private actor GatedOracle: WordOracle {
    private let inner: FakeWordOracle
    private var gate: CallGate

    init(misspelled: Set<String>, gated: Bool) {
        let entries = Dictionary(uniqueKeysWithValues: misspelled.map {
            ($0, FakeWordOracle.Entry(misspelled: true, english: false, stem: nil, lemma: nil, function: nil))
        })
        inner = FakeWordOracle(dictionary: ["en": entries])
        gate = CallGate(closed: gated)
    }

    func facts(for words: Set<String>, language: Language) async -> WordFacts {
        let index = gate.arrive()
        if gate.mustWait(index) {
            await withCheckedContinuation { gate.hold(index, $0) }
        }
        return await inner.facts(for: words, language: language)
    }

    func waitForCalls(_ count: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate.wait(id, for: count, $0) }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: UUID) {
        gate.stopWaiting(id)
    }

    func release(_ index: Int) {
        gate.release(index)
    }

    func open() {
        gate.open()
    }
}

private actor RecordingConfirmer: EditConfirming {
    private(set) var asked: [String] = []

    func confirm(_ edit: Edit, in paragraph: String, language: Language) -> Bool? {
        asked.append(edit.original)
        return true
    }
}

private struct Rig {
    let access = FakeTextAccess()
    let engine: FakeEngine
    let spelling: FakeSpelling
    let oracle: GatedOracle
    let confirmer = RecordingConfirmer()
    let clock = TestClock()
    let router: LiveRouter
    let pipeline: CheckPipeline

    init(
        _ settings: Settings,
        engine: FakeEngine = .correcting(["teh": "the"]),
        misspellings: [String: String] = ["teh": "the"],
        oracleGated: Bool = false,
        detector: any LanguageDetecting = FakeLanguageDetector()
    ) {
        self.engine = engine
        spelling = FakeSpelling(misspellings)
        oracle = GatedOracle(misspelled: Set(misspellings.keys.map { $0.lowercased() }), gated: oracleGated)
        router = LiveRouter(engineRouter(settings))
        pipeline = CheckPipeline(
            access: access,
            apple: engine,
            spelling: spelling,
            detector: detector,
            oracle: oracle,
            confirmer: confirmer,
            clock: clock,
            settings: settings,
            router: router
        )
    }

    func focus(_ text: String, caret: Int = 0) async {
        await access.set(text, caret: caret, in: fieldA)
        await pipeline.receive(.focused(fieldA))
    }

    /// Lets the typing pause run out; the timer's read and the checks it starts may still be running.
    func pass() {
        clock.advance(by: pause)
    }

    /// Moves the caret, lets the pause run out and waits for every check it starts.
    func recheckAtCaret() async {
        await pipeline.receive(.caretMoved(fieldA))
        pass()
        await pipeline.drain()
    }

    func check() async {
        pass()
        await pipeline.drain()
    }

    func visible(in field: FieldID = fieldA) async -> [Issue] {
        await pipeline.tracker.visible(in: field)
    }

    func modelIssues() async -> [Issue] {
        await visible().filter { $0.source == .model }
    }

    func update(_ settings: Settings, apple: UnavailableReason? = nil) async {
        await router.set(engineRouter(settings, apple: apple))
        await pipeline.update(settings: settings)
    }
}

private func next(
    _ iterator: inout AsyncStream<IssueSnapshot>.Iterator,
    where matches: (IssueSnapshot) -> Bool
) async -> IssueSnapshot? {
    while let snapshot = await iterator.next() {
        if matches(snapshot) { return snapshot }
    }
    return nil
}

@Suite(.timeLimit(.minutes(1)))
struct CheckPipelineTests {
    // MARK: Checking while typing

    @Test func aTypedParagraphShowsSpellingAfterThePauseThenModelIssues() async throws {
        let rig = Rig(makeSettings(), engine: .correcting(["teh": "the", "paris": "Paris"], gated: true))
        var published = rig.pipeline.issues.makeAsyncIterator()
        await rig.access.set(flew, caret: 3, in: fieldA)
        await rig.pipeline.start()

        rig.access.send(.focused(fieldA))
        await rig.clock.waitForSleepCalls(1)
        rig.access.send(.edited(fieldA))
        await rig.clock.waitForSleepCalls(2)
        rig.clock.advance(by: .milliseconds(699))
        await rig.pipeline.drain()
        #expect(await rig.access.reads == 0)

        rig.clock.advance(by: .milliseconds(1))
        await rig.engine.waitForRequests(1)
        let spelling = try #require(await published.next())
        #expect(spelling.field == fieldA)
        #expect(spelling.issues.map(\.word) == ["teh"])
        #expect(spelling.issues.map(\.source) == [.spelling])
        #expect(spelling.issues.map(\.edit.replacement) == ["the"])
        let request = try #require(await rig.engine.requests.first)
        #expect(request.action == .check)
        #expect(request.language == .en)
        #expect(request.text == flew)

        await rig.engine.open()
        await rig.pipeline.drain()
        let model = try #require(await published.next())
        #expect(model.issues.filter { $0.source == .spelling }.map(\.word) == ["teh"])
        #expect(model.issues.filter { $0.source == .model }.map(\.word) == ["teh", "paris"])
        #expect(model.issues.filter { $0.source == .model }.map(\.edit.replacement) == ["the", "Paris"])
        #expect(await rig.confirmer.asked == ["paris"])
        #expect(await rig.access.reads == 1)
    }

    @Test func tenEditsCostOneWindowedReadOfASixtyThousandUnitField() async {
        let paragraph = "We flew to teh office yesterday"
        let before = thread(30_000)
        let text = before + paragraph + "\n" + thread(30_000)
        #expect(text.utf16.count > 60_000)
        let rig = Rig(makeSettings())
        await rig.focus(text, caret: before.utf16.count + 3)

        for _ in 0..<10 {
            await rig.pipeline.receive(.edited(fieldA))
            rig.clock.advance(by: .milliseconds(50))
        }
        await rig.pipeline.drain()
        #expect(await rig.access.reads == 0)

        rig.clock.advance(by: .milliseconds(650))
        await rig.pipeline.drain()
        #expect(await rig.access.reads == 1)
        #expect(await rig.spelling.texts == [paragraph])
        #expect(await rig.engine.texts == [paragraph])
        #expect(await rig.visible().map(\.fieldRange.location) == [before.utf16.count + 11, before.utf16.count + 11])
    }

    // MARK: Stale reads

    private static let fixed = "We flew to the office in paris yesterday"

    /// Starts a read of `flew` and holds it, so the field can change before the read's answer arrives.
    private func holdARead(_ rig: Rig) async {
        await rig.access.holdSnapshots()
        await rig.focus(flew)
        rig.pass()
        await rig.access.waitForSnapshots(1)
    }

    /// Releases the held read with its old text, then lets the newer event's read run.
    private func releaseTheOldReadAndCheckAgain(_ rig: Rig) async {
        await rig.access.releaseSnapshot(0)
        await rig.pipeline.drain()
        await rig.access.stopHoldingSnapshots()
        await rig.check()
    }

    @Test func aReadAnsweredAfterAnEditIsDiscardedAndTheNextReadIsChecked() async {
        let rig = Rig(makeSettings())
        await holdARead(rig)
        await rig.access.set(Self.fixed, caret: 0, in: fieldA)
        await rig.pipeline.receive(.edited(fieldA))
        await releaseTheOldReadAndCheckAgain(rig)

        #expect(await rig.spelling.texts == [Self.fixed])
        #expect(await rig.engine.texts == [Self.fixed])
        #expect(await rig.visible().isEmpty)
    }

    @Test func aReadAnsweredAfterFocusWentAwayAndCameBackIsDiscarded() async {
        let rig = Rig(makeSettings())
        await holdARead(rig)
        await rig.pipeline.receive(.focused(fieldB))
        await rig.access.set(Self.fixed, caret: 0, in: fieldA)
        await rig.pipeline.receive(.focused(fieldA))
        await releaseTheOldReadAndCheckAgain(rig)

        #expect(await rig.spelling.texts == [Self.fixed])
        #expect(await rig.engine.texts == [Self.fixed])
    }

    /// An update that neither rechecks nor stops a check re-arms nothing of its own, so the read it made stale is
    /// taken again after the pause.
    @Test func aReadMadeStaleByAPlainUpdateIsTakenAgain() async {
        let settings = makeSettings()
        let rig = Rig(settings)
        await holdARead(rig)
        var neverTouch = settings
        neverTouch.addNeverTouch("Talos")
        await rig.update(neverTouch)
        await releaseTheOldReadAndCheckAgain(rig)

        #expect(await rig.access.reads == 2)
        #expect(await rig.spelling.texts == [flew])
        #expect(await Set(rig.visible().map(\.word)) == ["teh"])
    }

    @Test func textChangedDuringTheModelCheckDropsItsResult() async {
        let first = "We flew to teh office yesterday"
        let second = "We drove to teh depot today"
        let rig = Rig(makeSettings(), engine: .correcting(["teh": "the"], gated: true))
        await rig.focus(first)
        rig.pass()
        await rig.engine.waitForRequests(1)

        await rig.access.set(second, caret: 3, in: fieldA)
        await rig.pipeline.receive(.edited(fieldA))
        rig.pass()
        await rig.engine.waitForRequests(2)
        await rig.engine.release(0)
        await rig.engine.release(1)
        await rig.pipeline.drain()

        #expect(await rig.engine.texts == [first, second])
        #expect(await rig.engine.cancelled == [0])
        #expect(await rig.modelIssues().map(\.parent.text) == [second])
        #expect(await rig.visible().allSatisfy { $0.parent.text == second })
    }

    @Test func typingChecksOffForDutchSkipsSpellingAndTheModel() async {
        var settings = makeSettings()
        settings.typingChecks[.nl] = false
        let rig = Rig(settings, misspellings: ["gedownloaded": "gedownload"])
        await rig.focus("Ik heb de nieuwe versie gedownloaded")
        await rig.check()

        #expect(await rig.spelling.calls.isEmpty)
        #expect(await rig.engine.requests.isEmpty)
        #expect(await rig.visible().isEmpty)
    }

    @Test func aFieldKeepsItsLastConfidentLanguageAcrossFocusChanges() async {
        let rig = Rig(makeSettings(), misspellings: ["gedownloaded": "gedownload"])
        await rig.focus("Ik heb de nieuwe versie gedownloaded")
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldA) == nil)
        await rig.check()
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldA) == .nl)
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldB) == nil)
        await rig.pipeline.receive(.focused(nil))
        await rig.pipeline.receive(.focused(fieldB))
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldA) == .nl)
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldB) == nil)
    }

    @Test func aShortParagraphInheritsItsOwnFieldsLanguageAfterAnAppSwitch() async {
        let rig = Rig(makeSettings(), misspellings: ["gedownloaded": "gedownload", "morgn": "morgen"])
        await rig.focus("Ik heb de nieuwe versie gedownloaded")
        await rig.check()
        await rig.pipeline.receive(.focused(nil))
        await rig.access.set("Thanks for the review of the doc", caret: 0, in: fieldB)
        await rig.pipeline.receive(.focused(fieldB))
        await rig.check()
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldB) == .en)

        await rig.focus("tot morgn")
        await rig.check()
        #expect(await rig.spelling.calls.last?.language == .nl)
    }

    /// After a relaunch no field has a language yet: a short paragraph typed beside longer text took none and went unchecked.
    @Test func aShortParagraphInAFreshFieldTakesTheLanguageOfTheParagraphAboveIt() async {
        let rig = Rig(makeSettings(), misspellings: ["morgn": "morgen"])
        let text = "Ik heb de nieuwe versie gedownloaded.\n\ntot morgn"
        await rig.focus(text, caret: text.utf16.count)
        await rig.check()

        #expect(await rig.spelling.calls.count == 2)
        #expect(await rig.spelling.calls(of: "tot morgn").map(\.language) == [.nl])
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldA) == .nl)
    }

    /// Mixed text can detect as one language throughout: Notes scored a mostly English note Dutch, so every short
    /// English line in a fresh field was checked as Dutch.
    @Test func aShortParagraphInAFreshFieldTakesTheLanguageOfTheParagraphAboveItBeforeTheWholeText() async {
        let rig = Rig(makeSettings())
        let text = "Thanks for the review of the doc.\n\nteh end\n\nIk heb de nieuwe versie gedownloaded."
        await rig.focus(text, caret: 42)
        await rig.check()

        #expect(await rig.spelling.calls.count == 3)
        #expect(await rig.spelling.calls(of: "teh end").map(\.language) == [.en])
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldA) == .en)
    }

    @Test func theNearestParagraphAboveWinsOverAFartherOne() async {
        let rig = Rig(makeSettings())
        let text = "Ik heb de nieuwe versie gedownloaded.\n\nThanks for the review of the doc.\n\nteh end"
        await rig.focus(text, caret: text.utf16.count)
        await rig.check()

        #expect(await rig.spelling.calls.count == 3)
        #expect(await rig.spelling.calls(of: "teh end").map(\.language) == [.en])
    }

    /// No single paragraph detects, but the whole read does: the last resort before a paragraph goes unchecked.
    @Test func aParagraphNoNeighbourCanPlaceTakesTheLanguageOfTheWholeRead() async {
        let rig = Rig(makeSettings(), misspellings: ["morgn": "morgen"])
        let text = "Hi Jan,\n\nIk heb\n\ntot morgn"
        await rig.focus(text, caret: text.utf16.count)
        await rig.check()

        #expect(await rig.spelling.calls.count == 3)
        #expect(await rig.spelling.calls(of: "tot morgn").map(\.language) == [.nl])
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldA) == .nl)
    }

    @Test func aShortFirstParagraphInAFreshFieldTakesTheLanguageOfTheParagraphBelowIt() async {
        let rig = Rig(makeSettings())
        let text = "teh title\n\nThanks for the review of the doc.\n\nIk heb de nieuwe versie gedownloaded."
        await rig.focus(text, caret: 9)
        await rig.check()

        #expect(await rig.spelling.calls.count == 3)
        #expect(await rig.spelling.calls(of: "teh title").map(\.language) == [.en])
    }

    @Test func aShortParagraphAloneInAFreshFieldStaysUnchecked() async {
        let rig = Rig(makeSettings(), misspellings: ["morgn": "morgen"])
        await rig.focus("tot morgn", caret: 9)
        await rig.check()

        #expect(await rig.spelling.calls.isEmpty)
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldA) == nil)
    }

    @Test func onlyTheNewestTwentyFieldsKeepTheirLanguage() {
        var languages = FieldLanguages()
        let fields = (0...20).map { FieldID(app: "com.example.mail", token: "\($0)") }
        for field in fields { languages[field] = .fr }
        #expect(languages[fields[0]] == nil)
        #expect(languages[fields[1]] == .fr)
        languages[fields[1]] = .nl
        languages[FieldID(app: "com.example.mail", token: "new")] = .en
        #expect(languages[fields[1]] == .nl)
        #expect(languages[fields[2]] == nil)
    }

    @Test func anUnavailableAppleRouterCancelsTheSuspendedModelCheck() async {
        let settings = makeSettings()
        let rig = Rig(settings, engine: .correcting(["teh": "the", "paris": "Paris"], gated: true))
        await rig.focus(flew)
        rig.pass()
        await rig.engine.waitForRequests(1)

        await rig.update(settings, apple: .appleIntelligenceOff)
        await rig.engine.open()
        await rig.pipeline.drain()

        #expect(await rig.engine.cancelled == [0])
        #expect(await rig.visible().map(\.source) == [.spelling])
        #expect(await rig.visible().map(\.word) == ["teh"])
        #expect(await rig.confirmer.asked.isEmpty)
    }

    @Test func noConfirmationIsAskedOnceTheRouteLeavesTheModel() async {
        let settings = makeSettings()
        let rig = Rig(settings, engine: .correcting(["teh": "the", "paris": "Paris"]), oracleGated: true)
        await rig.focus(flew)
        rig.pass()
        await rig.oracle.waitForCalls(1)
        await rig.oracle.release(0)
        await rig.oracle.waitForCalls(2)

        await rig.router.set(engineRouter(settings, apple: .appleIntelligenceOff))
        await rig.oracle.open()
        await rig.pipeline.drain()

        #expect(await rig.confirmer.asked.isEmpty)
        #expect(await rig.engine.requests.count == 1)
        #expect(await rig.visible().map(\.source) == [.spelling])
    }

    @Test func aThreeChunkParagraphChecksItsChunksOneAfterAnother() async {
        let text = ["alpha", "beta", "gamma"].map(sentence).joined(separator: " ")
        let chunks = chunkTexts(text)
        #expect(chunks.count == 3)
        let rig = Rig(makeSettings(), engine: .correcting(["teh": "the"], gated: true), oracleGated: true)
        var published = rig.pipeline.issues.makeAsyncIterator()
        await rig.focus(text)
        rig.pass()
        await rig.oracle.waitForCalls(3)
        await rig.oracle.open()
        _ = await next(&published) { $0.issues.filter { $0.source == .spelling }.count == 3 }

        await rig.engine.waitForRequests(1)
        #expect(await rig.engine.texts == [chunks[0]])
        await rig.engine.release(0)
        _ = await next(&published) { $0.issues.contains { $0.source == .model } }
        await rig.engine.waitForRequests(2)
        #expect(await rig.engine.texts == [chunks[0], chunks[1]])
        await rig.engine.release(1)
        await rig.engine.waitForRequests(3)
        #expect(await rig.engine.texts == chunks)
        await rig.engine.release(2)
        await rig.pipeline.drain()

        #expect(await rig.modelIssues().map(\.key.chunk) == [0, 1, 2])
        #expect(await rig.modelIssues().map(\.chunk.text) == chunks)
    }

    @Test func aResultInAnotherLanguageIsDiscardedWholeAndCountsAsChecked() async {
        let rig = Rig(makeSettings(), engine: FakeEngine { request, _ in
            .success(replacingWords(in: request.text, ["teh": "the"]) + " J'ai")
        })
        await rig.focus(flew)
        await rig.check()
        #expect(await rig.modelIssues().isEmpty)
        #expect(await rig.visible().map(\.source) == [.spelling])

        await rig.recheckAtCaret()
        #expect(await rig.engine.texts == [flew])
    }

    @Test func aDistantParagraphKeepsItsIssuesAndIsNotCheckedAgainWhenUnchanged() async {
        let a = "We flew to teh office yesterday\n"
        let b = "They drove to teh depot today\n"
        let middle = thread(60_000)
        let rig = Rig(makeSettings())
        await rig.focus(a + middle + b, caret: 3)
        await rig.check()

        await rig.access.moveCaret(to: (a + middle).utf16.count + 3, in: fieldA)
        await rig.recheckAtCaret()
        await rig.access.moveCaret(to: 3, in: fieldA)
        await rig.recheckAtCaret()

        let paragraphA = String(a.dropLast())
        let paragraphB = String(b.dropLast())
        #expect(await rig.access.reads == 3)
        #expect(await rig.spelling.texts == [paragraphA, paragraphB])
        #expect(await rig.engine.texts == [paragraphA, paragraphB])
        #expect(await rig.visible().filter { $0.parent.text == paragraphA }.map(\.source) == [.spelling, .model])
        #expect(await rig.visible().filter { $0.parent.text == paragraphB }.count == 2)
    }

    @Test func aDistantParagraphThatChangedMeanwhileIsCheckedAgain() async {
        let a = "We flew to teh office yesterday\n"
        let changed = "We flew to teh office today\n"
        let b = "They drove to teh depot today\n"
        let middle = thread(60_000)
        let rig = Rig(makeSettings())
        await rig.focus(a + middle + b, caret: 3)
        await rig.check()

        await rig.access.set(changed + middle + b, caret: (changed + middle).utf16.count + 3, in: fieldA)
        await rig.recheckAtCaret()
        await rig.access.moveCaret(to: 3, in: fieldA)
        await rig.recheckAtCaret()

        let paragraphA = String(a.dropLast())
        let paragraphChanged = String(changed.dropLast())
        #expect(await rig.spelling.texts.filter { $0 == paragraphChanged }.count == 1)
        #expect(await rig.engine.texts.filter { $0 == paragraphChanged }.count == 1)
        #expect(await rig.visible().filter { $0.parent.text == paragraphA }.isEmpty)
        #expect(await rig.visible().filter { $0.parent.text == paragraphChanged }.map(\.source) == [.spelling, .model])
    }

    // MARK: Spelling the rest of the field in the background

    private static let dutchLine = "Ik heb de nieuwe versie gisteren gedownload."
    private static let englishLine = "Thanks for the review of the doc."
    private static let tehLines = [
        "We flew to teh office yesterday morning",
        "They drove to teh depot today evening",
        "She sent teh report to everyone",
    ]

    @Test func everyParagraphOfAWholeFieldIsSpelledAndOnlyTheCaretsParagraphReachesTheModel() async {
        let text = Self.tehLines.joined(separator: "\n")
        let rig = Rig(makeSettings())
        await rig.focus(text, caret: text.utf16.count)
        await rig.check()

        let spelled = await rig.visible().filter { $0.source == .spelling }
        #expect(spelled.map(\.parent.text) == Self.tehLines)
        #expect(spelled.map(\.word) == ["teh", "teh", "teh"])
        #expect(await rig.engine.texts == [Self.tehLines[2]])
    }

    /// A pass that set the field's language would leave the line typed next in Dutch.
    @Test func aShortLineTypedAtTheCaretAfterTheBackgroundPassIsCheckedInEnglish() async {
        let rig = Rig(makeSettings())
        let text = Self.dutchLine + "\n" + Self.englishLine
        await rig.focus(text, caret: text.utf16.count)
        await rig.check()
        #expect(await rig.spelling.calls(of: Self.dutchLine).map(\.language) == [.nl])

        let typed = text + "\nteh end"
        await rig.access.set(typed, caret: typed.utf16.count, in: fieldA)
        await rig.pipeline.receive(.edited(fieldA))
        await rig.check()
        #expect(await rig.spelling.calls(of: "teh end").map(\.language) == [.en])
    }

    /// The field's language is English here; a line among the Dutch paragraphs is Dutch.
    @Test func aShortLineAmongDutchParagraphsIsSpelledInDutchWhateverTheFieldsLanguage() async {
        let rig = Rig(makeSettings(), misspellings: ["morgn": "morgen"])
        let text = [Self.englishLine, Self.dutchLine, "tot morgn"].joined(separator: "\n")
        await rig.focus(text, caret: 3)
        await rig.check()

        #expect(await rig.spelling.calls(of: "tot morgn").map(\.language) == [.nl])
        #expect(await rig.pipeline.lastConfidentLanguage(for: fieldA) == .en)
    }

    @Test func aBackgroundJobSupersededByTheCaretsVisitEndsWithoutPublishing() async {
        let line = "teh end"
        let text = [Self.dutchLine, line, Self.englishLine].joined(separator: "\n")
        let rig = Rig(makeSettings())
        await rig.spelling.hold(line)
        await rig.focus(text, caret: text.utf16.count)
        rig.pass()
        await rig.spelling.waitForCalls(of: line, 1)

        await rig.access.moveCaret(to: Self.dutchLine.utf16.count + 3, in: fieldA)
        await rig.pipeline.receive(.caretMoved(fieldA))
        rig.pass()
        await rig.engine.waitForRequests(2)
        await rig.spelling.release(line)
        await rig.pipeline.drain()

        let flags = await rig.visible().filter { $0.parent.text == line && $0.source == .spelling }
        #expect(flags.map(\.word) == ["teh"])
        #expect(flags.map(\.language) == [.en])

        let spellingCalls = await rig.spelling.calls.count
        let requests = await rig.engine.requests.count
        await rig.recheckAtCaret()
        #expect(await rig.spelling.calls.count == spellingCalls)
        #expect(await rig.engine.requests.count == requests)
    }

    @Test func aFocusChangeDuringABackgroundLookupDropsTheRestOfThePass() async {
        let text = Self.tehLines.joined(separator: "\n")
        let rig = Rig(makeSettings(model: false), oracleGated: true)
        await rig.focus(text, caret: 3)
        rig.pass()
        await rig.oracle.waitForCalls(2)
        #expect(await rig.spelling.calls.count == 2)

        await rig.pipeline.receive(.focused(fieldB))
        await rig.oracle.open()
        await rig.pipeline.drain()

        #expect(await rig.visible(in: fieldA).isEmpty)
        #expect(await rig.spelling.calls.count == 2)
    }

    @Test func aNeverTouchUpdateMidPassSpellsTheHeldParagraphAgainAndEachOtherOnce() async {
        let settings = makeSettings(model: false)
        let rig = Rig(settings)
        var published = rig.pipeline.issues.makeAsyncIterator()
        let text = Self.tehLines.joined(separator: "\n")
        await rig.spelling.hold(Self.tehLines[1])
        await rig.focus(text, caret: 3)
        rig.pass()
        await rig.spelling.waitForCalls(of: Self.tehLines[1], 1)
        await rig.pipeline.drain(ignoringBackground: true)

        var updated = settings
        updated.addNeverTouch("Pieter")
        await rig.update(updated)
        await rig.access.set("\n" + text, caret: 4, in: fieldA)
        rig.pass()
        _ = await next(&published) { $0.issues.contains { $0.parent.text == Self.tehLines[0] && $0.parent.range.location == 1 } }
        await rig.spelling.release(Self.tehLines[1])
        await rig.pipeline.drain()

        #expect(await rig.spelling.calls(of: Self.tehLines[0]).count == 1)
        #expect(await rig.spelling.calls(of: Self.tehLines[1]).count == 2)
        #expect(await rig.spelling.calls(of: Self.tehLines[2]).count == 1)
    }

    @Test func aParagraphRoutedOffStaysSpellChecked() async {
        var settings = makeSettings()
        settings.typingChecks[.fr] = false
        let rig = Rig(settings)
        let french = "J'ai mergé le correctif hier soir."
        let text = french + "\n" + Self.tehLines[0]
        await rig.focus(text, caret: text.utf16.count)
        await rig.check()
        #expect(await rig.spelling.texts == [Self.tehLines[0]])

        await rig.router.set(engineRouter(makeSettings()))
        let edited = french + "\n" + Self.tehLines[1]
        await rig.access.set(edited, caret: edited.utf16.count, in: fieldA)
        await rig.pipeline.receive(.edited(fieldA))
        await rig.check()
        #expect(await rig.spelling.texts.filter { $0 == french }.isEmpty)
    }

    @Test func aPassCallsTheDetectorAtMostTwiceForEachParagraph() async {
        let detector = CountingLanguageDetector()
        let lines = (0..<40).map { "line \($0)" } + [Self.tehLines[0]]
        let text = lines.joined(separator: "\n")
        let rig = Rig(makeSettings(model: false), detector: detector)
        await rig.focus(text, caret: 3)
        await rig.check()

        #expect(await rig.spelling.calls.count == lines.count)
        #expect(detector.count <= 2 * lines.count + 2)
    }

    @Test func publishedRoutedOffAndDroppedEndingsEachAdvanceThePass() async {
        var settings = makeSettings(model: false)
        settings.typingChecks[.fr] = false
        let rig = Rig(settings)
        var published = rig.pipeline.issues.makeAsyncIterator()
        let french = "J'ai mergé le correctif hier soir."
        let dropped = Self.tehLines[2]
        let replacement = "She sent teh report to nobody"
        await rig.spelling.hold(dropped)
        let text = [Self.tehLines[0], Self.tehLines[1], french, dropped].joined(separator: "\n")
        await rig.focus(text, caret: 3)
        rig.pass()
        await rig.spelling.waitForCalls(of: dropped, 1)

        await rig.access.set("\n" + [Self.tehLines[0], Self.tehLines[1], french, replacement].joined(separator: "\n"), caret: 4, in: fieldA)
        await rig.pipeline.receive(.edited(fieldA))
        rig.pass()
        _ = await next(&published) { $0.issues.contains { $0.parent.text == Self.tehLines[0] && $0.parent.range.location == 1 } }
        await rig.spelling.release(dropped)
        await rig.pipeline.drain()

        let spelled = await rig.visible().filter { $0.source == .spelling }
        #expect(spelled.map(\.parent.text) == [Self.tehLines[0], Self.tehLines[1], replacement])
    }

    @Test func aFieldWhereNothingDetectsFinishesItsPassAndAsksTheDetectorOnlyAboutWhatChanged() async {
        let detector = CountingLanguageDetector()
        let rig = Rig(makeSettings(), detector: detector)
        let lines = ["aa", "bb", "cc", "dd"]
        func edit(line: String) async {
            let edited = [lines[0], line, lines[2], lines[3]].joined(separator: "\n")
            await rig.access.set(edited, caret: 4, in: fieldA)
            await rig.pipeline.receive(.edited(fieldA))
            await rig.check()
        }
        await rig.focus(lines.joined(separator: "\n"), caret: 4)
        await rig.check()
        #expect(await rig.spelling.calls.isEmpty)

        let before = detector.count
        await edit(line: "bx")
        #expect(detector.count - before == 2)
        #expect(await rig.spelling.calls.isEmpty)

        let beforeUndo = detector.count
        await edit(line: "bb")
        #expect(detector.count - beforeUndo == 2)

        await edit(line: Self.tehLines[0])
        #expect(await rig.spelling.texts.sorted() == [lines[0], lines[2], lines[3], Self.tehLines[0]].sorted())
    }

    // MARK: Lifecycle

    @Test func pausingDuringASpellingLookupPublishesNothing() async {
        let rig = Rig(makeSettings(), oracleGated: true)
        await rig.focus(flew)
        rig.pass()
        await rig.oracle.waitForCalls(1)

        await rig.pipeline.setPaused(true)
        await rig.oracle.open()
        await rig.pipeline.drain()

        #expect(await rig.visible().isEmpty)
        #expect(await rig.pipeline.lastPublished == IssueSnapshot(field: fieldA, issues: []))
        #expect(await rig.engine.requests.isEmpty)
    }

    @Test func aFocusChangeDuringASpellingLookupPublishesNothing() async {
        let rig = Rig(makeSettings(), oracleGated: true)
        await rig.focus(flew)
        rig.pass()
        await rig.oracle.waitForCalls(1)

        await rig.pipeline.receive(.focused(fieldB))
        await rig.oracle.open()
        await rig.pipeline.drain()

        #expect(await rig.visible(in: fieldA).isEmpty)
        #expect(await rig.pipeline.lastPublished == IssueSnapshot(field: fieldB, issues: []))
        #expect(await rig.engine.requests.isEmpty)
    }

    @Test func aRecheckToSpellingOnlyShowsTheSpellingFlagTheModelHadWithdrawn() async {
        let settings = makeSettings()
        let rig = Rig(settings, engine: FakeEngine { request, _ in .success(request.text) })
        await rig.focus(flew)
        await rig.check()
        #expect(await rig.visible().isEmpty)

        var spellingOnly = settings
        spellingOnly.modelChecks[.en] = false
        await rig.update(spellingOnly)
        await rig.check()

        #expect(await rig.visible().map(\.word) == ["teh"])
        #expect(await rig.visible().map(\.source) == [.spelling])
        #expect(await rig.engine.requests.count == 1)
    }

    @Test func aWithdrawnSpellingFlagStaysWithdrawnAfterAnEditAnUndoAndARefocus() async {
        let rig = Rig(makeSettings(), engine: FakeEngine { request, _ in .success(request.text) })
        await rig.focus(flew)
        await rig.check()
        #expect(await rig.visible().isEmpty)

        await rig.access.set("", caret: 0, in: fieldA)
        await rig.recheckAtCaret()
        await rig.access.set(flew, caret: 0, in: fieldA)
        await rig.recheckAtCaret()
        await rig.focus(flew)
        await rig.check()

        #expect(await rig.visible().isEmpty)
        #expect(await rig.engine.texts == [flew, flew])
    }

    // MARK: Never-touch words

    @Test func afterNeverFlagAndUpdateTheNextCheckOffersNoEditOnTheWord() async throws {
        let settings = makeSettings()
        let rig = Rig(settings, engine: .correcting(["Talos": "Thalos"]), misspellings: ["Talos": "Thalos"])
        await rig.focus(talos)
        await rig.check()
        #expect(await rig.visible().map(\.word) == ["Talos", "Talos"])

        let issue = try #require(await rig.visible().first)
        #expect(await rig.pipeline.neverFlag(issue.id) == "Talos")
        #expect(await rig.visible().isEmpty)
        var updated = settings
        updated.addNeverTouch("Talos")
        await rig.update(updated)
        await rig.recheckAtCaret()

        #expect(await rig.spelling.calls.map(\.neverTouch) == [[], ["Talos"]])
        #expect(await rig.engine.requests.count == 2)
        #expect(await rig.visible().isEmpty)
    }

    @Test func aNeverTouchWordAddedDuringTheOracleLookupIsNotPublished() async {
        let settings = makeSettings(model: false)
        let rig = Rig(settings, misspellings: ["Talos": "Thalos"], oracleGated: true)
        await rig.focus(talos)
        rig.pass()
        await rig.oracle.waitForCalls(1)

        var updated = settings
        updated.addNeverTouch("Talos")
        await rig.update(updated)
        await rig.oracle.open()
        await rig.pipeline.drain()

        #expect(await rig.spelling.calls.count == 1)
        #expect(await rig.visible().filter { $0.word == "Talos" }.isEmpty)
    }

    // MARK: Accept

    @Test func acceptSendsTheShiftedSpliceAndExpectedParagraphAndDropsTheIssue() async throws {
        let rig = Rig(makeSettings(model: false))
        await rig.focus("Hello there.\nWe flew to teh office", caret: 16)
        await rig.check()
        let issue = try #require(await rig.visible().first)

        #expect(await rig.pipeline.accept(issue.id) == .replaced)
        #expect(await rig.access.replacements == [FakeTextAccess.Replacement(
            range: TextRange(location: 23, length: 5),
            expected: ExpectedText(range: TextRange(location: 13, length: 21), text: "We flew to teh office"),
            text: " the ",
            field: fieldA
        )])
        #expect(await rig.visible().isEmpty)
    }

    @Test("Accepting a deletion at the end of the paragraph writes the neighbouring token, never an empty text",
          arguments: [("Thanks for the update, see you you", "you you", "you"), ("Thanks for the quick update!!", "!!", "!")])
    func acceptingADeletionAtTheEndNeverSendsAnEmptyText(_ text: String, _ replaced: String, _ written: String) async throws {
        let engine = FakeEngine { request, _ in
            .success(request.text.hasSuffix("you you") ? String(request.text.dropLast(4)) : String(request.text.dropLast()))
        }
        let rig = Rig(makeSettings(), engine: engine, misspellings: [:])
        await rig.focus(text)
        await rig.check()
        let issue = try #require(await rig.modelIssues().first)
        #expect(issue.edit.replacement.isEmpty)

        #expect(await rig.pipeline.accept(issue.id) == .replaced)
        let replacement = try #require(await rig.access.replacements.first)
        let at = (text as NSString).range(of: replaced, options: .backwards)
        #expect(replacement.range == TextRange(location: at.location, length: at.length))
        #expect(replacement.text == written)
        let result = (text as NSString).replacingCharacters(in: at, with: replacement.text)
        #expect(result == String(text.dropLast(replaced == "!!" ? 1 : 4)))
    }

    @Test func acceptingAFinalPunctuationFixAtAChunkBoundaryKeepsTheSpaceBeforeTheNextChunk() async throws {
        let first = "The first part needs an " + String(repeating: "more plain words here and ", count: 38) + "update!!"
        let second = sentence("beta")
        let text = first + " " + second
        #expect(chunkTexts(text) == [first + " ", second])
        let rig = Rig(makeSettings(), engine: .trimmingAndFixingDoubleBang, misspellings: [:])
        await rig.focus(text)
        await rig.check()
        let issue = try #require(await rig.modelIssues().first)

        #expect(await rig.pipeline.accept(issue.id) == .replaced)
        let replacement = try #require(await rig.access.replacements.first)
        let written = (text as NSString).replacingCharacters(
            in: NSRange(location: replacement.range.location, length: replacement.range.length), with: replacement.text
        )
        #expect(written == String(first.dropLast()) + " " + second)
    }

    @Test func aRefusedAcceptAlsoDropsTheIssue() async throws {
        let rig = Rig(makeSettings(model: false))
        await rig.access.answerReplacements(with: .refusedChanged)
        await rig.focus(flew)
        await rig.check()
        let issue = try #require(await rig.visible().first)

        #expect(await rig.pipeline.accept(issue.id) == .refusedChanged)
        #expect(await rig.access.replacements.count == 1)
        #expect(await rig.visible().isEmpty)
    }

    // MARK: Every dropped model check is reported as failed, so the next pause runs it again

    @Test func aRouteChangeDuringTheModelCheckDropsItAndTheNextPauseRetriesIt() async {
        let settings = makeSettings()
        let text = [sentence("alpha"), sentence("beta")].joined(separator: " ")
        let chunks = chunkTexts(text)
        let rig = Rig(settings, engine: .correcting(["teh": "the"], gated: true))
        await rig.focus(text)
        rig.pass()
        await rig.engine.waitForRequests(1)

        await rig.router.set(engineRouter(settings, apple: .modelNotReady))
        await rig.engine.release(0)
        await rig.pipeline.drain()
        #expect(await rig.engine.texts == [chunks[0]])
        #expect(await rig.modelIssues().isEmpty)

        await rig.router.set(engineRouter(settings))
        await rig.pipeline.receive(.caretMoved(fieldA))
        rig.pass()
        await rig.engine.waitForRequests(2)
        await rig.engine.open()
        await rig.pipeline.drain()
        #expect(await rig.engine.texts == [chunks[0], chunks[0], chunks[1]])
        #expect(await rig.modelIssues().map(\.key.chunk) == [0, 1])
    }

    @Test func aModelCheckCancelledByUpdateIsRetriedOnTheNextPause() async {
        let settings = makeSettings()
        let rig = Rig(settings, engine: .correcting(["teh": "the"], gated: true))
        await rig.focus(flew)
        rig.pass()
        await rig.engine.waitForRequests(1)

        await rig.update(settings, apple: .appleIntelligenceOff)
        await rig.engine.open()
        await rig.pipeline.drain()
        await rig.update(settings)
        await rig.recheckAtCaret()

        #expect(await rig.engine.texts == [flew, flew])
        #expect(await rig.modelIssues().map(\.word) == ["teh"])
    }

    @Test func anEngineFailureIsRetriedOnTheNextPause() async {
        let rig = Rig(makeSettings(), engine: FakeEngine { request, index in
            index == 0 ? .failure(.timedOut) : .success(replacingWords(in: request.text, ["teh": "the"]))
        })
        await rig.focus(flew)
        await rig.check()
        #expect(await rig.modelIssues().isEmpty)
        #expect(await rig.visible().map(\.source) == [.spelling])

        await rig.recheckAtCaret()
        #expect(await rig.engine.texts == [flew, flew])
        #expect(await rig.modelIssues().map(\.word) == ["teh"])
    }

    @Test func anUnavailableEngineMeansSpellingOnlyUntilTheNextUpdate() async {
        let settings = makeSettings()
        let rig = Rig(settings, engine: FakeEngine { request, index in
            index == 0 ? .failure(.unavailable(.modelNotReady)) : .success(replacingWords(in: request.text, ["teh": "the"]))
        })
        await rig.focus(flew)
        await rig.check()
        await rig.recheckAtCaret()
        #expect(await rig.engine.texts == [flew])
        #expect(await rig.visible().map(\.source) == [.spelling])

        await rig.update(settings)
        await rig.recheckAtCaret()
        #expect(await rig.engine.texts == [flew, flew])
        #expect(await rig.modelIssues().map(\.word) == ["teh"])
    }

    @Test func aModelResultForAVanishedParagraphIsDroppedAndRetried() async {
        let rig = Rig(makeSettings(), engine: .correcting(["teh": "the"], gated: true))
        var published = rig.pipeline.issues.makeAsyncIterator()
        await rig.focus(flew)
        rig.pass()
        await rig.engine.waitForRequests(1)

        await rig.access.set("", caret: 0, in: fieldA)
        await rig.pipeline.receive(.caretMoved(fieldA))
        rig.pass()
        _ = await next(&published) { $0.field == fieldA && $0.issues.isEmpty }
        await rig.engine.release(0)
        await rig.pipeline.drain()
        #expect(await rig.pipeline.tracker.visible(in: fieldA).isEmpty)

        await rig.access.set(flew, caret: 0, in: fieldA)
        await rig.pipeline.receive(.caretMoved(fieldA))
        rig.pass()
        await rig.engine.waitForRequests(2)
        await rig.engine.open()
        await rig.pipeline.drain()
        #expect(await rig.engine.texts == [flew, flew])
        #expect(await rig.modelIssues().map(\.word) == ["teh"])
    }

    @Test func aDiscardedAnswerForAVanishedParagraphIsNotRememberedAsChecked() async {
        let engine = FakeEngine(gated: true) { _, _ in .success("Something else entirely with none of the original words left") }
        let rig = Rig(makeSettings(), engine: engine)
        var published = rig.pipeline.issues.makeAsyncIterator()
        await rig.focus(flew)
        rig.pass()
        await rig.engine.waitForRequests(1)

        await rig.access.set("", caret: 0, in: fieldA)
        await rig.pipeline.receive(.caretMoved(fieldA))
        rig.pass()
        _ = await next(&published) { $0.field == fieldA && $0.issues.isEmpty }
        await rig.engine.release(0)
        await rig.pipeline.drain()

        await rig.engine.open()
        await rig.access.set(flew, caret: 0, in: fieldA)
        await rig.recheckAtCaret()
        #expect(await rig.engine.texts == [flew, flew])
        #expect(await rig.visible().map(\.word) == ["teh"])
    }

    @Test func anUpdateDuringAModelCheckCancelsItAndChecksTheFieldAgainAfterThePause() async {
        let settings = makeSettings()
        let rig = Rig(settings, engine: FakeEngine(gated: true) { request, index in
            .success(replacingWords(in: request.text, index == 0 ? ["paris": "Paris"] : ["teh": "the"]))
        })
        await rig.focus(flew)
        rig.pass()
        await rig.engine.waitForRequests(1)

        var updated = settings
        updated.addNeverTouch("Pieter")
        await rig.update(updated)
        await rig.engine.release(0)
        await rig.pipeline.drain()
        #expect(await rig.engine.cancelled == [0])
        #expect(await rig.modelIssues().isEmpty)
        #expect(await rig.access.reads == 1)

        rig.pass()
        await rig.engine.waitForRequests(2)
        await rig.engine.open()
        await rig.pipeline.drain()
        #expect(await rig.access.reads == 2)
        #expect(await rig.engine.texts == [flew, flew])
        #expect(await rig.modelIssues().map(\.word) == ["teh"])
        #expect(await rig.confirmer.asked.isEmpty)
    }

    @Test func anUnavailableAnswerFromAnEarlierEpochLeavesTheModelOn() async {
        let settings = makeSettings()
        let rig = Rig(settings, engine: FakeEngine(gated: true) { request, index in
            index == 0 ? .failure(.unavailable(.modelNotReady)) : .success(replacingWords(in: request.text, ["teh": "the"]))
        })
        await rig.focus(flew)
        rig.pass()
        await rig.engine.waitForRequests(1)

        await rig.update(settings)
        await rig.engine.open()
        await rig.pipeline.drain()
        await rig.check()

        #expect(await rig.engine.texts == [flew, flew])
        #expect(await rig.modelIssues().map(\.word) == ["teh"])
    }

    @Test func anUpdateDropsTheRunningChunkWithoutStartingTheNextOneEarly() async {
        let settings = makeSettings()
        let text = [sentence("alpha"), sentence("beta")].joined(separator: " ")
        let chunks = chunkTexts(text)
        let rig = Rig(settings, engine: .correcting(["teh": "the"], gated: true))
        await rig.focus(text)
        rig.pass()
        await rig.engine.waitForRequests(1)

        var updated = settings
        updated.addNeverTouch("Pieter")
        await rig.update(updated)
        await rig.engine.open()
        await rig.pipeline.drain()
        #expect(await rig.engine.texts == [chunks[0]])
        #expect(await rig.modelIssues().isEmpty)

        await rig.check()
        #expect(await rig.engine.texts == [chunks[0], chunks[0], chunks[1]])
        #expect(await rig.modelIssues().map(\.key.chunk) == [0, 1])
    }

    @Test func spellingDiscardedByAnUpdateRunsAgainAfterThePause() async {
        let settings = makeSettings(model: false)
        let rig = Rig(settings, oracleGated: true)
        await rig.focus(flew)
        rig.pass()
        await rig.oracle.waitForCalls(1)

        var updated = settings
        updated.addNeverTouch("Pieter")
        await rig.update(updated)
        rig.pass()
        await rig.oracle.waitForCalls(2)
        await rig.oracle.open()
        await rig.pipeline.drain()

        #expect(await rig.access.reads == 2)
        #expect(await rig.spelling.calls.count == 2)
        #expect(await rig.visible().map(\.word) == ["teh"])
        #expect(await rig.visible().map(\.source) == [.spelling])
    }

    // MARK: Lifetime and test support

    @Test func theIssuesStreamFinishesWhenThePipelineGoesAway() async {
        var published: AsyncStream<IssueSnapshot>.Iterator
        do {
            let rig = Rig(makeSettings())
            published = rig.pipeline.issues.makeAsyncIterator()
            await rig.pipeline.start()
            await rig.focus(flew)
        }
        #expect(await next(&published) { _ in false } == nil)
    }

    @Test func theTestClockWakesDueSleepersInDeadlineOrder() async throws {
        let clock = TestClock()
        let late = Task { try await clock.sleep(until: clock.now.advanced(by: .milliseconds(200))) }
        await clock.waitForSleepCalls(1)
        let early = Task { try await clock.sleep(until: clock.now.advanced(by: .milliseconds(100))) }
        await clock.waitForSleepCalls(2)
        clock.advance(by: .milliseconds(300))
        try await late.value
        try await early.value
        #expect(clock.wokenDeadlines.map(\.offset) == [.milliseconds(100), .milliseconds(200)])
    }
}
