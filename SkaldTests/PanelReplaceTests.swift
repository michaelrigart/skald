import Foundation
import SkaldCore
import struct SkaldCore.TextRange
import Testing
@testable import Skald

nonisolated private let original = "We flew to teh office"
nonisolated private let revised = "We flew to the office"

nonisolated private func revisedResult(_ text: String = revised, engine: EngineKind = .thisMac) -> PanelResult {
    .revised(text: text, edits: TextDiff.edits(from: original, to: text), engine: engine)
}

/// Answers runs from `results` in order, then with the revised text; with `answers`, each run waits for one.
private actor FakeSession: PanelSessioning {
    private let outcome: ReplaceOutcome
    private var results: [PanelResult]
    private let answers: AsyncStream<PanelResult>?
    nonisolated let started: AsyncStream<Void>
    private nonisolated let starts: AsyncStream<Void>.Continuation
    private(set) var replaced: [String] = []
    private(set) var runs: [EngineAction] = []
    private(set) var chosen: [Language] = []

    init(outcome: ReplaceOutcome = .replaced, results: [PanelResult] = [], answers: AsyncStream<PanelResult>? = nil) {
        self.outcome = outcome
        self.results = results
        self.answers = answers
        (started, starts) = AsyncStream.makeStream(of: Void.self)
    }

    func run(_ a: EngineAction, on e: EngineKind?) async -> PanelResult {
        runs.append(a)
        starts.yield()
        if let answers {
            for await answer in answers { return answer }
        }
        return results.isEmpty ? revisedResult(engine: e ?? .thisMac) : results.removeFirst()
    }

    func replace(with text: String) -> ReplaceOutcome {
        replaced.append(text)
        return outcome
    }

    func choose(_ language: Language) {
        chosen.append(language)
    }
}

private final class WindowRecorder: PanelPresenting {
    private(set) var events: [String] = []

    func show() { events.append("show") }
    func hide() { events.append("hide") }
}

/// Counts focus waits and answers each with `focused`.
private final class FocusWait {
    private(set) var waits = 0
    let focused: Bool

    init(focused: Bool) {
        self.focused = focused
    }

    func wait() async -> Bool {
        waits += 1
        return focused
    }
}

@MainActor struct PanelReplaceTests {
    private let spy = ClipboardSpy()
    private let window = WindowRecorder()

    private func panel(outcome: ReplaceOutcome = .replaced, focused: Bool = true, writes: Bool = true) async
        -> (PanelController, FakeSession, FocusWait) {
        let session = FakeSession(outcome: outcome)
        let focus = FocusWait(focused: focused)
        let controller = PanelController(window: window, clipboard: spy)
        controller.open(PanelOpening(
            session: session, text: original,
            target: .init(writes: writes, returnFocus: { await focus.wait() }),
            engines: [.thisMac, .claude], engine: .thisMac
        ))
        await controller.perform(.fix)
        return (controller, session, focus)
    }

    /// Catches a slow capture from an earlier hotkey press reopening a panel the user closed.
    @Test func anObsoleteOpeningNeverOpensThePanel() {
        let controller = PanelController(window: window, clipboard: spy)
        let opening = PanelOpening(session: FakeSession(outcome: .replaced), text: original, target: nil, engines: [.thisMac], engine: .thisMac)
        let first = controller.reserveOpening()
        let second = controller.reserveOpening()
        #expect(!controller.open(opening, reserved: first))
        #expect(controller.open(opening, reserved: second))
        controller.close()
        #expect(!controller.open(opening, reserved: second))
        #expect(!controller.open(opening, reserved: first))
        #expect(!controller.isOpen)
        #expect(window.events == ["show", "hide"])
    }

    @Test func aCloseBeforeTheCaptureEndsKeepsThePanelClosed() {
        let controller = PanelController(window: window, clipboard: spy)
        let opening = PanelOpening(session: FakeSession(outcome: .replaced), text: original, target: nil, engines: [.thisMac], engine: .thisMac)
        let pressed = controller.reserveOpening()
        controller.close()
        #expect(!controller.open(opening, reserved: pressed))
        #expect(!controller.isOpen)
    }

    @Test func aConfirmedReplaceClosesThePanelAfterTheFieldHasFocusAgain() async {
        let (controller, session, focus) = await panel(outcome: .replaced)
        #expect(controller.offersReplace)
        await controller.replace()
        #expect(focus.waits == 1)
        #expect(await session.replaced == [revised])
        #expect(!controller.isOpen)
        #expect(window.events == ["show", "hide", "hide"])
        #expect(spy.writes.isEmpty)
    }

    @Test(arguments: [
        (ReplaceOutcome.unsupported, "Skald can't write in this field. Copy the result instead."),
        (.clipboardBusy, "Skald can't paste while the clipboard holds protected content or an earlier fix. Copy the result instead."),
        (.failed, "The change didn't go through."),
        (.refusedChanged, "The text changed since Skald read it."),
        (.refusedOtherField, "The field isn't focused any more."),
    ])
    func aRefusedReplaceReopensWithTheResultCopyAndAReason(outcome: ReplaceOutcome, reason: String) async {
        let (controller, session, _) = await panel(outcome: outcome)
        await controller.replace()
        #expect(await session.replaced == [revised])
        #expect(controller.isOpen)
        #expect(window.events == ["show", "hide", "show"])
        #expect(controller.revised == revised)
        #expect(controller.reason == reason)
        #expect(controller.offersCopy)
        #expect(!controller.offersReplace)
        #expect(spy.writes.isEmpty)
    }

    @Test func aMissedFocusReopensWithoutWritingAndOffersCopy() async {
        let (controller, session, focus) = await panel(focused: false)
        await controller.replace()
        #expect(focus.waits == 1)
        #expect(await session.replaced.isEmpty)
        #expect(controller.isOpen)
        #expect(window.events == ["show", "hide", "show"])
        #expect(controller.revised == revised)
        #expect(controller.reason == "The field isn't focused any more.")
        #expect(controller.offersCopy)
        #expect(!controller.offersReplace)
        #expect(spy.writes.isEmpty)
    }

    @Test func anUnconfirmedPasteReopensSayingTheClipboardHoldsTheResult() async {
        let (controller, _, _) = await panel(outcome: .unconfirmed)
        await controller.replace()
        #expect(controller.isOpen)
        #expect(controller.revised == revised)
        #expect(controller.reason == "The app didn't show the change. The clipboard now holds the result.")
        #expect(!controller.offersReplace)
        #expect(!controller.offersCopy)
        #expect(spy.writes.isEmpty)
    }

    @Test(arguments: [ReplaceOutcome.unsupported, .clipboardBusy, .failed, .refusedChanged, .refusedOtherField])
    func copyAfterARefusalWritesTheResultExactlyOnce(outcome: ReplaceOutcome) async {
        let (controller, _, _) = await panel(outcome: outcome)
        await controller.replace()
        controller.copy()
        #expect(spy.writes == [revised])
        #expect(controller.copied)
    }

    @Test func copyAfterAMissedFocusWritesTheResultExactlyOnce() async {
        let (controller, _, _) = await panel(focused: false)
        await controller.replace()
        controller.copy()
        #expect(spy.writes == [revised])
    }

    @Test func anAppThatCantBeWrittenToOffersOnlyCopy() async {
        let (controller, session, focus) = await panel(writes: false)
        #expect(!controller.offersReplace)
        #expect(controller.offersCopy)
        await controller.replace()
        #expect(focus.waits == 0)
        #expect(await session.replaced.isEmpty)
        #expect(spy.writes.isEmpty)
        controller.copy()
        #expect(spy.writes == [revised])
    }

    @Test func clipboardTextIsLabelledAndAFieldsTextIsNot() {
        let controller = PanelController(window: window, clipboard: spy)
        var opening = PanelOpening(session: FakeSession(), text: original, target: nil, engines: [.thisMac], engine: .thisMac)
        opening.fromClipboard = true
        controller.open(opening)
        #expect(controller.fromClipboard)
        #expect(PanelController.clipboardLabel == "Text from the clipboard")

        opening.fromClipboard = false
        controller.open(opening)
        #expect(!controller.fromClipboard)
    }

    @Test func withoutACapturedFieldThePanelOffersOnlyCopy() async {
        let controller = PanelController(window: window, clipboard: spy)
        let session = FakeSession(outcome: .replaced)
        controller.open(PanelOpening(session: session, text: original, target: nil, engines: [.thisMac], engine: .thisMac))
        await controller.perform(.shorter)
        #expect(controller.revised == revised)
        #expect(!controller.offersReplace)
        #expect(controller.offersCopy)
        await controller.replace()
        #expect(await session.replaced.isEmpty)
        #expect(spy.writes.isEmpty)
    }

    @Test func theResultIsNeverCopiedWithoutPressingCopy() async {
        let (controller, _, _) = await panel()
        #expect(controller.revised == revised)
        #expect(spy.writes.isEmpty)
    }

    @Test func anOpeningDuringAReplaceIsRefusedAndTheOutcomeStillReopensWithItsReason() async {
        let controller = PanelController(window: window, clipboard: spy)
        let session = FakeSession(outcome: .refusedChanged)
        var refused: Bool?
        controller.open(PanelOpening(
            session: session, text: original,
            target: .init(writes: true, returnFocus: {
                refused = !controller.open(PanelOpening(
                    session: FakeSession(), text: "Another selection", target: nil, engines: [.thisMac], engine: .thisMac
                ))
                return true
            }),
            engines: [.thisMac], engine: .thisMac
        ))
        await controller.perform(.fix)
        await controller.replace()

        #expect(refused == true)
        #expect(await session.replaced == [revised])
        #expect(controller.isOpen)
        #expect(controller.original == original)
        #expect(controller.revised == revised)
        #expect(controller.reason == "The text changed since Skald read it.")
        #expect(controller.offersCopy)
        #expect(spy.writes.isEmpty)
    }

    @Test func aResultThatChangesNothingOffersNoReplace() async {
        let controller = PanelController(window: window, clipboard: spy)
        let session = FakeSession(results: [revisedResult(original)])
        controller.open(PanelOpening(
            session: session, text: original, target: .init(writes: true, returnFocus: { true }), engines: [.thisMac], engine: .thisMac
        ))
        await controller.perform(.fix)
        #expect(controller.revised == original)
        #expect(!controller.offersReplace)
        await controller.replace()
        #expect(await session.replaced.isEmpty)
    }

    @Test func anEngineCancelEndsTheRunWithStoppedInsteadOfSpinning() async {
        let controller = PanelController(window: window, clipboard: spy)
        controller.open(PanelOpening(
            session: FakeSession(results: [.failed(.cancelled)]), text: original, target: nil, engines: [.thisMac], engine: .thisMac
        ))
        await controller.perform(.shorter)
        #expect(controller.phase == .finished(.failed(.cancelled)))
    }

    @Test func theRunningPhaseNamesTheEngineThatRunsNotThePickersCurrentOne() async {
        let (answers, answer) = AsyncStream.makeStream(of: PanelResult.self)
        let session = FakeSession(answers: answers)
        let controller = PanelController(window: window, clipboard: spy)
        controller.open(PanelOpening(session: session, text: original, target: nil, engines: [.thisMac, .claude], engine: .thisMac))
        controller.engine = .claude
        let run = Task { await controller.perform(.fix) }
        var started = session.started.makeAsyncIterator()
        _ = await started.next()
        controller.engine = .thisMac
        #expect(controller.phase == .running(.fix, on: .claude))
        answer.yield(revisedResult(engine: .claude))
        await run.value
        #expect(controller.phase == .finished(revisedResult(engine: .claude)))
    }

    @Test func anUndetectableSelectionAsksForALanguageBeforeAnyRun() async {
        let session = FakeSession()
        let controller = PanelController(window: window, clipboard: spy)
        var opening = PanelOpening(session: session, text: "morgen", target: nil, engines: [.thisMac], engine: .thisMac)
        opening.needsLanguage = true
        controller.open(opening)
        #expect(controller.phase == .choosingLanguage)
        #expect(!controller.canRun)
        await controller.perform(.fix)
        #expect(await session.runs.isEmpty)

        await controller.choose(.nl)
        #expect(await session.chosen == [.nl])
        #expect(controller.phase == .ready)
        await controller.perform(.fix)
        #expect(await session.runs == [.fix])
    }

    @Test func aRunThatNeedsALanguageAsksAndRunsAgainOnThePick() async {
        let session = FakeSession(results: [.needsLanguage])
        let controller = PanelController(window: window, clipboard: spy)
        controller.open(PanelOpening(session: session, text: original, target: nil, engines: [.thisMac], engine: .thisMac))
        await controller.perform(.shorter)
        #expect(controller.phase == .choosingLanguage)
        await controller.choose(.fr)
        #expect(await session.chosen == [.fr])
        #expect(await session.runs == [.shorter, .shorter])
        #expect(controller.revised == revised)
    }

    @Test func aFieldSkaldCantReadOffersNothingToRun() async {
        let session = FakeSession()
        let controller = PanelController(window: window, clipboard: spy)
        var opening = PanelOpening(session: session, text: "", target: nil, engines: [.thisMac], engine: .thisMac)
        opening.notice = PanelController.unreadableNotice
        controller.open(opening)
        #expect(controller.phase == .blocked("Skald can't read this field here."))
        await controller.perform(.fix)
        #expect(await session.runs.isEmpty)
    }
}

private let notes = FieldID(app: "com.example.notes", token: "1")

@MainActor struct PanelContentTests {
    private let capture = SelectionCapture(
        field: notes, selection: TextRange(location: 0, length: 3), selectedText: "teh",
        context: ExpectedText(range: TextRange(location: 0, length: 7), text: "teh cat")
    )

    @Test func aCapturedFieldIsWorkedOnWithoutReadingTheClipboard() {
        var reads = 0
        let content = PanelContent.resolve(focused: notes, capture: capture) { reads += 1; return "copied" }
        #expect(content == .field(capture))
        #expect(reads == 0)
    }

    @Test func aFocusedFieldThatCantBeCapturedIsUnreadableAndTheClipboardIsLeftAlone() {
        var reads = 0
        let content = PanelContent.resolve(focused: notes, capture: nil) { reads += 1; return "copied" }
        #expect(content == .unreadable)
        #expect(reads == 0)
    }

    @Test func withNoFocusedFieldTheClipboardsTextIsUsed() {
        #expect(PanelContent.resolve(focused: nil, capture: nil) { "copied" } == .clipboard("copied"))
        #expect(PanelContent.resolve(focused: nil, capture: nil) { nil } == .clipboard(""))
    }
}
