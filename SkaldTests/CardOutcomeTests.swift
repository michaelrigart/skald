import Foundation
import SkaldCore
import Testing
@testable import Skald

@MainActor struct CardOutcomeTests {
    private let spy = ClipboardSpy()
    private let flagged = issue(in: "They is ready", revised: "They are ready")

    private func card(writes: Bool = true, answer: ReplaceOutcome = .replaced) -> IssueCardModel {
        IssueCardModel(
            issue: flagged, writes: writes, clipboard: spy,
            actions: .init(accept: { _ in answer }, ignore: { _ in }, neverFlag: { _ in })
        )
    }

    @Test func aReplacedFixClosesTheCard() async {
        let card = card(answer: .replaced)
        await card.accept()
        #expect(card.phase == .closed)
        #expect(spy.writes.isEmpty)
    }

    @Test(arguments: [
        (ReplaceOutcome.unsupported, "Skald can't write in this field. Copy the fix instead."),
        (.clipboardBusy, "Skald can't paste while the clipboard holds protected content or an earlier fix. Copy the fix instead."),
        (.failed, "The change didn't go through."),
        (.refusedChanged, "The text changed since Skald checked it."),
        (.refusedOtherField, "The field isn't focused any more."),
    ])
    func aRefusedOrFailedFixKeepsTheCardOpenWithCopyAndAReason(outcome: ReplaceOutcome, reason: String) async {
        let card = card(answer: outcome)
        await card.accept()
        #expect(card.phase == .finished(reason: reason, offersCopy: true))
        #expect(card.offersCopy)
        #expect(spy.writes.isEmpty)
    }

    /// The pipeline has already dropped the issue; the clipboard holds the fix, so the card says so and offers no copy.
    @Test func anUnconfirmedPasteKeepsTheCardOpenAndSaysTheClipboardHoldsTheFix() async {
        let card = card(answer: .unconfirmed)
        await card.accept()
        #expect(card.phase == .finished(reason: "The app didn't show the change. The clipboard now holds the fix.", offersCopy: false))
        #expect(!card.offersCopy)
        #expect(spy.writes.isEmpty)
    }

    @Test(arguments: [ReplaceOutcome.unsupported, .clipboardBusy, .failed, .refusedChanged, .refusedOtherField])
    func copyFixAfterARefusalWritesTheFixExactlyOnce(outcome: ReplaceOutcome) async {
        let card = card(answer: outcome)
        await card.accept()
        card.copyFix()
        #expect(spy.writes == ["are"])
    }

    @Test func aReadOnlyAppOffersCopyFixInsteadOfAccept() {
        let card = card(writes: false)
        #expect(card.phase == .ready)
        #expect(card.offersCopy)
        #expect(!card.offersAccept)
        card.copyFix()
        #expect(spy.writes == ["are"])
    }

    @Test func aWritableAppOffersAcceptAndNoCopy() {
        let card = card(writes: true)
        #expect(card.offersAccept)
        #expect(!card.offersCopy)
    }

    @Test func acceptShowsThatItIsWorkingUntilTheOutcome() async {
        let (answers, answer) = AsyncStream.makeStream(of: ReplaceOutcome.self)
        let card = IssueCardModel(
            issue: flagged, writes: true, clipboard: spy,
            actions: .init(
                accept: { _ in
                    for await answer in answers { return answer }
                    return .failed
                },
                ignore: { _ in }, neverFlag: { _ in }
            )
        )
        let accepting = Task { await card.accept() }
        while card.phase != .working { await Task.yield() }
        #expect(!card.offersAccept)
        answer.yield(.failed)
        await accepting.value
        #expect(card.phase == .finished(reason: "The change didn't go through.", offersCopy: true))
    }

    @Test func ignoreAndNeverFlagCloseTheCardAndNameTheIssue() {
        var ignored: [UUID] = []
        var neverFlagged: [UUID] = []
        let actions = IssueCardModel.Actions(accept: { _ in .replaced }, ignore: { ignored.append($0) }, neverFlag: { neverFlagged.append($0) })
        let first = IssueCardModel(issue: flagged, writes: true, clipboard: spy, actions: actions)
        first.ignore()
        let second = IssueCardModel(issue: flagged, writes: true, clipboard: spy, actions: actions)
        second.neverFlag()
        #expect(first.phase == .closed && second.phase == .closed)
        #expect(ignored == [flagged.id] && neverFlagged == [flagged.id])
        #expect(spy.writes.isEmpty)
    }

    /// The card keeps its own copy of the fix, since `accept` drops the issue whatever the outcome.
    @Test func aReadyCardGoesWithItsIssueButAFinishedOneOutlivesIt() async {
        let ready = card()
        #expect(ready.survives(visible: [flagged.id], in: flagged.key.field))
        #expect(!ready.survives(visible: [], in: flagged.key.field))
        #expect(!ready.survives(visible: [flagged.id], in: nil))

        let finished = card(answer: .failed)
        await finished.accept()
        #expect(finished.survives(visible: [], in: flagged.key.field))
        finished.copyFix()
        #expect(spy.writes == ["are"])
    }

    /// Catches a finished card following the user to another app or Space.
    @Test func aFinishedCardClosesWhenItsFieldLosesFocus() async {
        let finished = card(answer: .unconfirmed)
        await finished.accept()
        #expect(!finished.survives(visible: [], in: nil))
        #expect(!finished.survives(visible: [], in: FieldID(app: "com.example.other", token: "2")))
    }

    @Test func aWorkingCardStaysUntilItsOutcomeWhereverFocusGoes() async {
        let (answers, answer) = AsyncStream.makeStream(of: ReplaceOutcome.self)
        let card = IssueCardModel(
            issue: flagged, writes: true, clipboard: spy,
            actions: .init(
                accept: { _ in
                    for await answer in answers { return answer }
                    return .failed
                },
                ignore: { _ in }, neverFlag: { _ in }
            )
        )
        let accepting = Task { await card.accept() }
        while card.phase != .working { await Task.yield() }
        #expect(card.survives(visible: [], in: nil))
        answer.yield(.replaced)
        await accepting.value
    }

    // MARK: Ruling R121: a write that finishes after focus moved

    private let otherField = FieldID(app: "com.example.other", token: "2")

    /// Accepts on a card whose answer waits; focus moves to `otherField` while it works, then `outcome` arrives and
    /// the card's `onFinish` hands it to `parking`.
    private func finishAfterFocusMoved(_ outcome: ReplaceOutcome, parking: inout CardParking) async -> (IssueCardModel, CardParking.AfterFinish?) {
        let (answers, answer) = AsyncStream.makeStream(of: ReplaceOutcome.self)
        let card = IssueCardModel(
            issue: flagged, writes: true, clipboard: spy,
            actions: .init(
                accept: { _ in
                    for await answer in answers { return answer }
                    return .failed
                },
                ignore: { _ in }, neverFlag: { _ in }
            )
        )
        var after: CardParking.AfterFinish?
        var local = parking
        let other = otherField
        card.onFinish = { after = local.finished(card, focused: other, anchor: .zero, screen: .zero, issues: []) }
        let accepting = Task { await card.accept() }
        while card.phase != .working { await Task.yield() }
        #expect(card.survives(visible: [], in: otherField))
        answer.yield(outcome)
        await accepting.value
        parking = local
        return (card, after)
    }

    @Test func anUnconfirmedCardFinishedAfterFocusMovedIsHiddenThenShownWhenItsFieldIsFocusedAgain() async {
        var parking = CardParking()
        let (card, after) = await finishAfterFocusMoved(.unconfirmed, parking: &parking)
        #expect(after == .hides)
        #expect(parking.received(IssueSnapshot(field: otherField, issues: [])) == nil)
        #expect(parking.received(IssueSnapshot(field: flagged.key.field, issues: []))?.card === card)
        #expect(card.phase == .finished(reason: "The app didn't show the change. The clipboard now holds the fix.", offersCopy: false))
        #expect(parking.received(IssueSnapshot(field: flagged.key.field, issues: [])) == nil)
    }

    @Test func aFailedCardFinishedAfterFocusMovedClosesAndIsNotShownAgain() async {
        var parking = CardParking()
        let (_, after) = await finishAfterFocusMoved(.failed, parking: &parking)
        #expect(after == .closes)
        #expect(parking.received(IssueSnapshot(field: otherField, issues: [])) == nil)
        #expect(parking.received(IssueSnapshot(field: flagged.key.field, issues: [])) == nil)
    }

    @Test func aParkedCardIsDroppedWhenAnotherCardOpensOrItsFieldsIssuesChanged() async {
        var opened = CardParking()
        _ = await finishAfterFocusMoved(.unconfirmed, parking: &opened)
        opened.otherCardOpened()
        #expect(opened.received(IssueSnapshot(field: flagged.key.field, issues: [])) == nil)

        var changed = CardParking()
        _ = await finishAfterFocusMoved(.unconfirmed, parking: &changed)
        let another = issue(in: "We was late", revised: "We were late")
        #expect(changed.received(IssueSnapshot(field: flagged.key.field, issues: [another])) == nil)
        #expect(changed.received(IssueSnapshot(field: flagged.key.field, issues: [])) == nil)
    }

    @Test func aCardFinishedWhileItsFieldKeepsFocusStays() async {
        let finished = card(answer: .unconfirmed)
        await finished.accept()
        var parking = CardParking()
        #expect(parking.finished(finished, focused: flagged.key.field, anchor: .zero, screen: .zero, issues: []) == .stays)
        #expect(parking.parked == nil)
    }

    /// A deletion has no text to copy, so the reason mustn't tell the user to copy it.
    @Test func aRefusedDeletionOffersNoCopyAndItsReasonSaysNoneIsOffered() async {
        let deletion = IssueCardModel(
            issue: issue(in: "It is is ready", revised: "It is ready"), writes: true, clipboard: spy,
            actions: .init(accept: { _ in .unsupported }, ignore: { _ in }, neverFlag: { _ in })
        )
        await deletion.accept()
        #expect(deletion.phase == .finished(reason: "Skald can't write in this field.", offersCopy: false))
        #expect(!deletion.offersCopy)
        deletion.copyFix()
        #expect(spy.writes.isEmpty)
    }

    /// Catches a caret move (typing, arrow keys, Skald's own selection) closing a card the user is reading.
    @Test func aCaretMoveKeepsAReadyCardAndAWindowMoveOrScrollClosesIt() {
        let ready = card()
        #expect(ready.survives(.caret))
        #expect(!ready.survives(.window))
        #expect(!ready.survives(.scroll))
    }

    @Test func aFinishedCardOutlivesWindowMovesAndScrolls() async {
        let finished = card(answer: .failed)
        await finished.accept()
        #expect(finished.survives(.window) && finished.survives(.scroll) && finished.survives(.caret))
    }

    @Test func theCardShowsTheWordInItsContext() {
        let content = CardContent(issue: issue(in: "👍🏽 Ik heb het gedownloaded.", revised: "👍🏽 Ik heb het gedownload."))
        #expect(content == CardContent(before: "👍🏽 Ik heb het ", original: "gedownloaded", replacement: "gedownload", after: "."))
    }

    /// The context is cut by UTF-16 units; a cut inside an emoji widens to keep it whole.
    @Test func aContextCutInsideAnEmojiKeepsTheEmojiWhole() {
        let prefix = "👍🏽" + String(repeating: "b", count: 28) + " "
        let content = CardContent(issue: issue(in: prefix + "teh end", revised: prefix + "the end"), context: 30)
        #expect(content.before == prefix)
        #expect(content.original == "teh")
    }

    @Test func aLongContextIsCutWithAnEllipsis() {
        let prefix = String(repeating: "a ", count: 30)
        let content = CardContent(issue: issue(in: prefix + "teh end", revised: prefix + "the end"), context: 10)
        #expect(content.before == "…" + String(repeating: "a ", count: 5))
    }
}
