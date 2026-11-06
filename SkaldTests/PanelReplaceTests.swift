import Foundation
import SkaldCore
import Testing
@testable import Skald

nonisolated private let original = "We flew to teh office"
nonisolated private let revised = "We flew to the office"

private actor FakeSession: PanelSessioning {
    private let outcome: ReplaceOutcome
    private(set) var replaced: [String] = []

    init(outcome: ReplaceOutcome) {
        self.outcome = outcome
    }

    func run(_ a: EngineAction, on e: EngineKind?) -> PanelResult {
        .revised(text: revised, edits: TextDiff.edits(from: original, to: revised), engine: e ?? .thisMac)
    }

    func replace(with text: String) -> ReplaceOutcome {
        replaced.append(text)
        return outcome
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

    @Test(arguments: [ReplaceOutcome.unsupported, .failed, .refusedChanged, .refusedOtherField])
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
}
