import Foundation
import SkaldCore
import struct SkaldCore.Issue
import Testing
@testable import Skald

/// A sleep the test ends by hand.
@MainActor private final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var asked: [Duration] = []

    func sleep(_ duration: Duration) async {
        asked.append(duration)
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Ends the longest-waiting sleep only.
    func releaseOldest() async {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
        await settle()
    }

    func open() async {
        isOpen = true
        let sleepers = waiting
        waiting = []
        sleepers.forEach { $0.resume() }
        await settle()
    }
}

@MainActor private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

private final class Announcer: Announcing {
    private(set) var said: [String] = []

    func announce(_ text: String) {
        said.append(text)
    }
}

@MainActor final class ReviewSessionTests {
    private let a = issue(in: "word", revised: "wordt", at: 4)
    private let b = issue(in: "word", revised: "wordt", at: 20)
    private let c = issue(in: "word", revised: "wordt", at: 31)

    private let registrar: FakeRegistrar
    private let announcer = Announcer()
    private let gate = Gate()
    private var list: [Issue]
    private var writes = true
    /// The answers of the writes in order; the last one repeats.
    private var outcomes = [ReplaceOutcome.replaced]
    private var shown: [Issue] = []
    private var places: [(index: Int, count: Int)] = []
    private var accepting: [UUID] = []
    private var alternatives: [String?] = []
    /// What the card of the accept in question says about it, by issue.
    private var reasons: [UUID: String] = [:]
    private var copied: [UUID] = []
    private var dismissed: [UUID] = []
    private var checkingShown = 0
    private var closed = 0
    private var session: ReviewSession!

    init() {
        registrar = FakeRegistrar()
        list = [a, b]
        session = make(registrar)
    }

    private func make(_ registrar: FakeRegistrar) -> ReviewSession {
        let gate = gate
        let keys = ReviewKeys(registrar: registrar, sleep: { await gate.sleep($0) })
        return ReviewSession(
            keys: keys, announcer: announcer, sleep: { await gate.sleep($0) },
            actions: .init(
                issues: { [unowned self] in list },
                writes: { [unowned self] in writes },
                show: { [unowned self] issue, index, count in
                    shown.append(issue)
                    places.append((index, count))
                },
                accept: { [unowned self] id, alternative in
                    accepting.append(id)
                    alternatives.append(alternative)
                    return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
                },
                reason: { [unowned self] in reasons[$0] },
                copy: { [unowned self] in copied.append($0) },
                dismiss: { [unowned self] in dismissed.append($0) },
                showChecking: { [unowned self] in checkingShown += 1 },
                close: { [unowned self] in closed += 1 }
            )
        )
    }

    private func tap(_ code: UInt16) {
        registrar.press(code)
        registrar.lift(code)
    }

    @Test func openingHoldsTheKeysShowsTheFirstIssueAndAnnouncesIt() {
        session.toggle()
        #expect(registrar.held.count == 6 && session.isOpen)
        #expect(shown.map(\.id) == [a.id])
        #expect(announcer.said == ["Grammar: word, change to wordt. 1 of 2"])
    }

    @Test func aFieldWithoutIssuesOpensNothing() {
        list = []
        session.toggle()
        #expect(!session.isOpen && registrar.held.isEmpty && shown.isEmpty && closed == 0)
        #expect(announcer.said == ["No suggestions"])
    }

    @Test func theModeStaysClosedWhenTheKeysAreRefused() {
        let refusing = FakeRegistrar(refusing: [36])
        let session = make(refusing)
        session.toggle()
        #expect(!session.isOpen && refusing.held.isEmpty && shown.isEmpty && closed == 0)
        #expect(announcer.said == ["Review isn't available"])
    }

    @Test func theAnnouncementSaysThePlaceInTheList() {
        #expect(ReviewSession.announcement(label: "Grammar: word, change to wordt", index: 1, count: 5) == "Grammar: word, change to wordt. 2 of 5")
    }

    @Test func theKeysStepThroughTheIssuesAndSayWhereTheyAre() {
        list = [a, b, c]
        session.toggle()
        tap(124)
        tap(48)
        tap(123)
        #expect(shown.map(\.id) == [a.id, b.id, c.id, b.id])
        #expect(places.map { $0.index } == [0, 1, 2, 1] && places.allSatisfy { $0.count == 3 })
        #expect(announcer.said.last == "Grammar: word, change to wordt. 2 of 3")
    }

    @Test func escLeavesAndFreesTheKeys() {
        session.toggle()
        tap(53)
        #expect(!session.isOpen && registrar.held.isEmpty && closed == 1)
    }

    @Test func aDismissHandsTheIssueOnAndShowsTheNextOne() {
        session.toggle()
        tap(51)
        #expect(dismissed == [a.id] && shown.map(\.id) == [a.id, b.id])
        #expect(places.last?.index == 0 && places.last?.count == 1)
        #expect(announcer.said.last == "Grammar: word, change to wordt. 1 of 1")
    }

    @Test func aDismissedIssueIsNotSteppedBackToBeforeThePipelineHasDroppedIt() {
        session.toggle()
        tap(51)
        tap(123)
        #expect(shown.map(\.id) == [a.id, b.id])
        session.snapshot([b], checked: true, sameField: true)
        tap(123)
        #expect(shown.map(\.id) == [a.id, b.id])
    }

    @Test func anAcceptWaitsForTheRecheckThenShowsTheNextIssue() async {
        session.toggle()
        tap(36)
        await settle()
        #expect(accepting == [a.id])
        #expect(checkingShown == 1 && announcer.said.last == "Checking…" && registrar.held.count == 6)
        session.snapshot([], checked: false, sameField: true)
        #expect(session.isOpen)
        session.snapshot([b], checked: true, sameField: true)
        #expect(shown.map(\.id) == [a.id, b.id])
        #expect(announcer.said.last == "Grammar: word, change to wordt. 1 of 1")
        await gate.open()
        #expect(session.isOpen && registrar.held.count == 6 && closed == 0)
    }

    @Test func aRecheckThatFinishedBeforeTheOutcomeGoesOnAtOnce() async {
        session.toggle()
        tap(36)
        session.snapshot([], checked: false, sameField: true)
        session.snapshot([b], checked: true, sameField: true)
        #expect(shown.map(\.id) == [a.id])
        await settle()
        #expect(shown.map(\.id) == [a.id, b.id] && checkingShown == 0)
    }

    @Test func theWaitIsTheModesRecheckWait() async {
        session.toggle()
        tap(36)
        await settle()
        #expect(gate.asked == [ReviewMode.recheckWait])
    }

    @Test func theWaitRunningOutEndsTheModeAndFreesTheKeys() async {
        session.toggle()
        tap(36)
        await settle()
        await gate.open()
        #expect(!session.isOpen && registrar.held.isEmpty && closed == 1)
        #expect(announcer.said.last == "Review ended")
    }

    @Test func aWaitLeftBehindDoesNotEndALaterOpeningsWait() async {
        session.toggle()
        tap(36)
        await settle()
        tap(53)
        #expect(!session.isOpen && registrar.held.isEmpty && closed == 1)
        session.toggle()
        tap(36)
        await settle()
        await gate.releaseOldest()
        #expect(session.isOpen && registrar.held.count == 6 && closed == 1)
        await gate.open()
        #expect(!session.isOpen && closed == 2)
    }

    @Test(arguments: [ReplaceOutcome.failed, .refusedChanged, .refusedOtherField, .unsupported, .clipboardBusy, .unconfirmed])
    func aWriteThatIsNotConfirmedEndsTheMode(_ answer: ReplaceOutcome) async {
        outcomes = [answer]
        session.toggle()
        tap(36)
        await settle()
        #expect(!session.isOpen && registrar.held.isEmpty && closed == 1 && checkingShown == 0)
        #expect(announcer.said.last == "Review ended")
    }

    @Test func anUnconfirmedWriteSaysWhyItsCardStaysOpen() async {
        outcomes = [.unconfirmed]
        reasons[a.id] = "The app didn't show the change. The clipboard now holds the fix."
        session.toggle()
        tap(36)
        await settle()
        #expect(!session.isOpen && closed == 1)
        #expect(announcer.said.last == "The app didn't show the change. The clipboard now holds the fix.")
        #expect(announcer.said.filter { $0 == "Review ended" }.isEmpty)
    }

    @Test func theOutcomeOfAWriteLeftBehindDoesNotReachALaterOpening() async {
        outcomes = [.failed, .replaced]
        session.toggle()
        tap(36)
        tap(53)
        session.toggle()
        tap(36)
        await settle()
        #expect(accepting == [a.id, a.id])
        #expect(session.isOpen && checkingShown == 1 && closed == 1)
    }

    @Test func noKeyIsHeldOnceTheModeIsClosed() {
        let leaves: [(ReviewSession) -> Void] = [
            { $0.toggle() }, { $0.snapshot([], checked: false, sameField: false) }, { $0.snapshot([], checked: true, sameField: true) },
            { $0.edited() }, { $0.left() },
        ]
        for leave in leaves {
            let registrar = FakeRegistrar()
            let session = make(registrar)
            session.toggle()
            #expect(registrar.held.count == 6 && session.isOpen)
            leave(session)
            #expect(!session.isOpen && registrar.held.isEmpty)
            #expect(announcer.said.last == "Review ended")
        }
    }

    @Test func withoutACleanWriteReturnCopies() {
        writes = false
        session.toggle()
        tap(36)
        #expect(copied == [a.id] && session.isOpen && accepting.isEmpty)
    }

    @Test func nothingIsHeldOrShownAfterTheModeEnded() {
        session.toggle()
        tap(53)
        session.snapshot([a, b], checked: true, sameField: true)
        session.edited()
        session.left()
        #expect(shown.map(\.id) == [a.id] && closed == 1 && registrar.held.isEmpty)
    }

    @Test func aGuessAcceptedWithTheMouseGoesThroughTheModeAndWaitsForTheRecheck() async {
        session.toggle()
        session.accept(alternative: "ten")
        await settle()
        #expect(accepting == [a.id] && alternatives == ["ten"])
        #expect(session.isOpen && registrar.held.count == 6 && checkingShown == 1)
        session.edited()
        #expect(session.isOpen)
        session.snapshot([], checked: false, sameField: true)
        session.snapshot([b], checked: true, sameField: true)
        #expect(shown.map(\.id) == [a.id, b.id])
    }

    @Test func theKeyAcceptsTheFixItself() async {
        session.toggle()
        tap(36)
        await settle()
        #expect(alternatives == [nil])
    }

    @Test func aMouseDismissMovesOnLikeTheKey() {
        session.toggle()
        session.dismiss()
        #expect(dismissed == [a.id] && shown.map(\.id) == [a.id, b.id])
    }
}
