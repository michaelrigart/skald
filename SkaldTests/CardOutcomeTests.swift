import Foundation
import SkaldCore
import struct SkaldCore.Issue
import Testing
@testable import Skald

@MainActor struct CardOutcomeTests {
    private let spy = ClipboardSpy()
    private let flagged = issue(in: "They is ready", revised: "They are ready")

    private func card(writes: Bool = true, answer: ReplaceOutcome = .replaced) -> IssueCardModel {
        IssueCardModel(
            issue: flagged, writes: writes, clipboard: spy,
            actions: .init(accept: { _, _ in answer }, dismiss: { _ in }, addToDictionary: { _ in }, hide: { _ in })
        )
    }

    @Test func aCardForAnIssueClaudeFoundSaysClaude() {
        func model(_ engine: EngineKind?, source: IssueSource = .model) -> IssueCardModel {
            IssueCardModel(
                issue: issue(in: "They is ready", revised: "They are ready", source: source, engine: engine), writes: true, clipboard: spy,
                actions: .init(accept: { _, _ in .replaced }, dismiss: { _ in }, addToDictionary: { _ in }, hide: { _ in })
            )
        }
        #expect(model(.claude).byClaude)
        #expect(!model(.thisMac).byClaude)
        #expect(!model(nil, source: .spelling).byClaude)
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
                accept: { _, _ in
                    for await answer in answers { return answer }
                    return .failed
                },
                dismiss: { _ in }, addToDictionary: { _ in }, hide: { _ in }
            )
        )
        let accepting = Task { await card.accept() }
        while card.phase != .working { await Task.yield() }
        #expect(!card.offersAccept)
        answer.yield(.failed)
        await accepting.value
        #expect(card.phase == .finished(reason: "The change didn't go through.", offersCopy: true))
    }

    @Test func dismissAndAddToDictionaryCloseTheCardAndNameTheIssue() {
        var dismissed: [UUID] = []
        var added: [UUID] = []
        let actions = IssueCardModel.Actions(
            accept: { _, _ in .replaced }, dismiss: { dismissed.append($0) }, addToDictionary: { added.append($0) }, hide: { _ in }
        )
        let first = IssueCardModel(issue: flagged, writes: true, clipboard: spy, actions: actions)
        first.dismiss()
        let second = IssueCardModel(issue: flagged, writes: true, clipboard: spy, actions: actions)
        second.addToDictionary()
        #expect(first.phase == .closed && second.phase == .closed)
        #expect(dismissed == [flagged.id] && added == [flagged.id])
        #expect(spy.writes.isEmpty)
    }

    // MARK: The kind, the alternatives, the menu and the labels

    private func card(
        _ issue: Issue, accept: @escaping (UUID, Int?) async -> ReplaceOutcome = { _, _ in .replaced }, hide: @escaping (IssueKind) -> Void = { _ in }
    ) -> IssueCardModel {
        IssueCardModel(
            issue: issue, writes: true, clipboard: spy,
            actions: .init(accept: accept, dismiss: { _ in }, addToDictionary: { _ in }, hide: hide)
        )
    }

    /// A spelling issue on "teh end" whose first guess is its edit and whose other guesses are its alternatives.
    private func spelling(guesses: [String]) -> Issue {
        let text = "teh end"
        let others = guesses.dropFirst().map { guess in
            guard let edit = TextDiff.edits(from: text, to: "\(guess) end").first else { fatalError("no edit to \(guess)") }
            return edit
        }
        return issue(in: text, revised: "\(guesses[0]) end", source: .spelling, alternatives: others)
    }

    @Test func theCardSaysItsKindAndOffersToHideOnlyAHideableOne() {
        let verb = card(issue(in: "Het word morgen.", revised: "Het wordt morgen.", kind: .verbForm))
        #expect(verb.headline == "Grammar · Verb form")
        #expect(verb.hideTitle == #"Hide "Verb form" suggestions"#)
        #expect(card(issue(in: "I has it.", revised: "I have it.", kind: .grammar)).hideTitle == nil)
        #expect(card(issue(in: "teh end", revised: "the end", source: .spelling)).hideTitle == nil)
        #expect(card(issue(in: "Fine", revised: "Fine.", kind: .punctuation)).hideTitle == #"Hide "Punctuation" suggestions"#)
    }

    @Test func theLabelNamesTheCategoryAndTheChange() {
        #expect(card(issue(in: "Het word morgen.", revised: "Het wordt morgen.", kind: .verbForm)).label == "Grammar: word, change to wordt")
        #expect(card(issue(in: "Fine", revised: "Fine.", kind: .punctuation)).label == "Punctuation: add .")
        #expect(card(issue(in: "See you you soon.", revised: "See you soon.", kind: .repeatedWord)).label == "Grammar: remove you")
    }

    @Test func theLabelIsAvailableWithoutACard() {
        let verb = issue(in: "Het word morgen.", revised: "Het wordt morgen.", kind: .verbForm)
        #expect(IssueCardModel.label(for: verb) == card(verb).label)
    }

    @Test func hidingCallsTheActionWithTheKindAndCloses() {
        var hidden: [IssueKind] = []
        let card = card(issue(in: "Fine", revised: "Fine.", kind: .punctuation), hide: { hidden.append($0) })
        card.hide()
        #expect(hidden == [.punctuation] && card.phase == .closed)
    }

    @Test func aKindThatCannotBeHiddenIsNotHidden() {
        var hidden: [IssueKind] = []
        let card = card(issue(in: "I has it.", revised: "I have it.", kind: .grammar), hide: { hidden.append($0) })
        card.hide()
        #expect(hidden.isEmpty && card.phase == .ready)
    }

    @Test func anAlternativeIsAcceptedByItsIndex() async {
        var asked: [Int?] = []
        let card = card(spelling(guesses: ["the", "ten", "tea"]), accept: { _, index in asked.append(index); return .replaced })
        #expect(card.alternatives == ["ten", "tea"])
        await card.accept(alternative: 1)
        #expect(asked == [1] && card.phase == .closed)
    }

    @Test func acceptWithoutAnAlternativeAsksForTheFix() async {
        var asked: [Int?] = []
        let card = card(spelling(guesses: ["the", "ten"]), accept: { _, index in asked.append(index); return .replaced })
        await card.accept()
        #expect(asked == [nil])
    }

    @Test func theDictionaryItemNamesTheWordAndAnInsertionHasNone() {
        #expect(card(issue(in: "teh end", revised: "the end", source: .spelling)).dictionaryTitle == #"Add "teh" to dictionary"#)
        #expect(card(issue(in: "Fine", revised: "Fine.", kind: .punctuation)).dictionaryTitle == nil)
    }

    @Test func theKeyLineShowsOnlyInReviewWhileTheCardIsReady() async {
        let card = card(issue(in: "Fine", revised: "Fine.", kind: .punctuation))
        #expect(!card.showsReviewKeys)
        card.reviewing = true
        #expect(card.showsReviewKeys)
        await card.accept()
        #expect(!card.showsReviewKeys)
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
                accept: { _, _ in
                    for await answer in answers { return answer }
                    return .failed
                },
                dismiss: { _ in }, addToDictionary: { _ in }, hide: { _ in }
            )
        )
        let accepting = Task { await card.accept() }
        while card.phase != .working { await Task.yield() }
        #expect(card.survives(visible: [], in: nil))
        answer.yield(.replaced)
        await accepting.value
    }

    // MARK: Rulings R121 and R123: a write that finishes after focus moved

    private let otherField = FieldID(app: "com.example.other", token: "2")

    /// Accepts on a card whose answer waits; focus moves to `otherField` while it works, then `outcome` arrives and
    /// the card's `onFinish` hands it to `parking`.
    private func finishAfterFocusMoved(_ outcome: ReplaceOutcome, parking: inout CardParking) async -> (IssueCardModel, CardParking.AfterFinish?) {
        let (answers, answer) = AsyncStream.makeStream(of: ReplaceOutcome.self)
        let card = IssueCardModel(
            issue: flagged, writes: true, clipboard: spy,
            actions: .init(
                accept: { _, _ in
                    for await answer in answers { return answer }
                    return .failed
                },
                dismiss: { _ in }, addToDictionary: { _ in }, hide: { _ in }
            )
        )
        var after: CardParking.AfterFinish?
        var local = parking
        let other = otherField
        card.onFinish = { after = local.finished(card, focused: other, anchor: .zero, screen: .zero) }
        let accepting = Task { await card.accept() }
        while card.phase != .working { await Task.yield() }
        #expect(card.survives(visible: [], in: otherField))
        answer.yield(outcome)
        await accepting.value
        parking = local
        return (card, after)
    }

    /// The field changes while focus is away; the notice doesn't depend on the issues, before or after the re-check.
    @Test func anUnconfirmedCardFinishedAfterFocusMovedComesBackOnceAsAClipboardNoticeThatAnEditCloses() async {
        var parking = CardParking()
        let (card, after) = await finishAfterFocusMoved(.unconfirmed, parking: &parking)
        #expect(after == .hides)
        #expect(parking.received(IssueSnapshot(field: otherField, issues: [], checked: true)) == nil)

        let cached = issue(in: "We was late", revised: "We were late")
        let shown = parking.received(IssueSnapshot(field: flagged.key.field, issues: [cached], checked: true))
        #expect(shown?.card === card)
        #expect(card.phase == .notice)
        #expect(!card.offersAccept && !card.offersCopy && card.dictionaryTitle == nil && card.hideTitle == nil)
        #expect(parking.parked == nil)

        let revalidated = issue(in: "We was late today", revised: "We were late today")
        #expect(parking.received(IssueSnapshot(field: flagged.key.field, issues: [revalidated], checked: true)) == nil)
        #expect(card.survives(visible: [revalidated.id], in: flagged.key.field))
        #expect(card.phase == .notice)
        #expect(card.survives(.caret))
        #expect(!card.survives(.edit))
        #expect(!card.survives(visible: [], in: otherField))
    }

    @Test func aFailedCardFinishedAfterFocusMovedClosesAndIsNotShownAgain() async {
        var parking = CardParking()
        let (_, after) = await finishAfterFocusMoved(.failed, parking: &parking)
        #expect(after == .closes)
        #expect(parking.received(IssueSnapshot(field: otherField, issues: [], checked: true)) == nil)
        #expect(parking.received(IssueSnapshot(field: flagged.key.field, issues: [], checked: true)) == nil)
    }

    @Test func aParkedCardIsDroppedWhenAnotherCardOpens() async {
        var parking = CardParking()
        let (card, _) = await finishAfterFocusMoved(.unconfirmed, parking: &parking)
        parking.otherCardOpened()
        #expect(parking.received(IssueSnapshot(field: flagged.key.field, issues: [], checked: true)) == nil)
        #expect(card.phase != .notice)
    }

    @Test func aCardFinishedWhileItsFieldKeepsFocusStays() async {
        let finished = card(answer: .unconfirmed)
        await finished.accept()
        var parking = CardParking()
        #expect(parking.finished(finished, focused: flagged.key.field, anchor: .zero, screen: .zero) == .stays)
        #expect(parking.parked == nil)
    }

    /// An edit only redraws a ready or finished card; their own rules end them.
    @Test func anEditKeepsReadyAndFinishedCards() async {
        #expect(card().survives(.edit))
        let finished = card(answer: .failed)
        await finished.accept()
        #expect(finished.survives(.edit))
    }

    /// A deletion has no text to copy, so the reason mustn't tell the user to copy it.
    @Test func aRefusedDeletionOffersNoCopyAndItsReasonSaysNoneIsOffered() async {
        let deletion = IssueCardModel(
            issue: issue(in: "It is is ready", revised: "It is ready"), writes: true, clipboard: spy,
            actions: .init(accept: { _, _ in .unsupported }, dismiss: { _ in }, addToDictionary: { _ in }, hide: { _ in })
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
