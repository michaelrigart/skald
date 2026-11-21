import Foundation
import Testing
@testable import SkaldCore
import struct SkaldCore.Issue
import struct SkaldCore.TextRange

private let field = FieldID(app: "app", token: "a")

private func fixture(at offset: Int) -> Issue {
    let text = "teh"
    let key = ParagraphKey(field: field, text: text, position: .location(offset), chunk: 0)
    let paragraph = Paragraph(range: TextRange(location: offset, length: text.utf16.count), text: text)
    let edit = TextDiff.edits(from: text, to: "the")[0]
    return Issue(key: key, parent: paragraph, chunk: paragraph, edit: edit, source: .spelling, language: .en)
}

private extension Issue {
    func moved(to offset: Int, id: UUID? = nil) -> Issue {
        let moved = Paragraph(range: TextRange(location: offset, length: chunk.range.length), text: chunk.text)
        return Issue(id: id ?? self.id, key: key, parent: moved, chunk: moved, edit: edit, source: source, language: language)
    }
}

private let a = fixture(at: 4)
private let b = fixture(at: 20)
private let c = fixture(at: 31)

private func open(_ issues: [Issue]) -> ReviewMode {
    var mode = ReviewMode()
    _ = mode.toggle(issues: issues)
    return mode
}

@Test func theShortcutOpensOnTheFirstIssueAndLeavesWhenPressedAgain() {
    var mode = ReviewMode()
    #expect(mode.toggle(issues: []) == [] && !mode.holdsKeys)
    #expect(mode.toggle(issues: [a, b, c]) == [.show(a.id)])
    #expect(mode.phase == .showing(a.id) && mode.position == 4 && mode.holdsKeys)
    #expect(mode.toggle(issues: [a, b, c]) == [.close])
    #expect(mode.phase == .closed && !mode.holdsKeys)
}

@Test func nextAndPreviousMoveToTheNeighbourOrByPositionWhenTheShownIssueIsGone() {
    var mode = open([a, b, c])
    #expect(mode.key(.next, issues: [a, b, c], writes: true) == [.show(b.id)])
    #expect(mode.key(.next, issues: [a, c], writes: true) == [.show(c.id)])        // b went meanwhile: the first after 20
    #expect(mode.key(.next, issues: [a, c], writes: true) == [])
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [.show(b.id)])
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [.show(a.id)])
    #expect(mode.key(.previous, issues: [a, b, c], writes: true) == [])
}

@Test func twoIssuesAtOneOffsetAreBothReachable() {
    let twin = b.moved(to: 4, id: UUID())                             // a second issue starting at 4
    var mode = open([a, twin, c])
    #expect(mode.key(.next, issues: [a, twin, c], writes: true) == [.show(twin.id)])
    #expect(mode.key(.next, issues: [a, twin, c], writes: true) == [.show(c.id)])
    #expect(mode.key(.previous, issues: [a, twin, c], writes: true) == [.show(twin.id)])
}

@Test func afterAConfirmedWriteTheModeWaitsForTheRecheckAndGoesOn() {
    var mode = open([a, b, c])
    #expect(mode.key(.accept, issues: [a, b, c], writes: true) == [.accept(a.id)])
    #expect(mode.phase == .applying(a.id))
    for key in [ReviewMode.Key.next, .previous, .accept, .dismiss] { #expect(mode.key(key, issues: [a, b, c], writes: true) == []) }
    #expect(mode.issuesChanged([b, c], checked: true) == [])          // the pipeline dropped the accepted issue
    #expect(mode.finished(.replaced) == [.wait(a.id, .seconds(8))])
    #expect(mode.phase == .awaiting(a.id) && mode.holdsKeys)
    for key in [ReviewMode.Key.next, .previous, .accept, .dismiss] { #expect(mode.key(key, issues: [], writes: true) == []) }
    #expect(mode.edited() == [])                                      // Skald's own write
    #expect(mode.issuesChanged([b, c], checked: true) == [])          // published before the suspension: the old list
    #expect(mode.issuesChanged([], checked: false) == [])             // suspended while the field is read again
    #expect(mode.issuesChanged([b.moved(to: 21), c.moved(to: 32)], checked: true) == [.show(b.id)])
    #expect(mode.phase == .showing(b.id) && mode.position == 21)
    #expect(mode.waitEnded(a.id) == [])                               // the wait is over already
}

@Test func theSuspensionMayArriveBeforeTheOutcome() {
    var mode = open([a, b, c])
    _ = mode.key(.accept, issues: [a, b, c], writes: true)
    #expect(mode.issuesChanged([], checked: false) == [])             // while applying
    #expect(mode.finished(.replaced) == [.wait(a.id, .seconds(8))])
    #expect(mode.issuesChanged([b.moved(to: 21), c.moved(to: 32)], checked: true) == [.show(b.id)])
}

@Test func aRecheckThatFinishedBeforeTheWriteWasConfirmedIsUsedAtOnce() {
    var mode = open([a, b, c])
    _ = mode.key(.accept, issues: [a, b, c], writes: true)
    #expect(mode.issuesChanged([], checked: false) == [])
    #expect(mode.issuesChanged([b.moved(to: 21), c.moved(to: 32)], checked: true) == [])
    #expect(mode.finished(.replaced) == [.show(b.id)])
    #expect(mode.phase == .showing(b.id) && mode.position == 21)
    var empty = open([a])
    _ = empty.key(.accept, issues: [a], writes: true)
    _ = empty.issuesChanged([], checked: false)
    #expect(empty.issuesChanged([], checked: true) == [])
    #expect(empty.finished(.replaced) == [.close])
    #expect(!empty.holdsKeys)
}

@Test func aCheckedListBeforeTheSuspensionOrForgottenByALaterOneIsNeverUsed() {
    var stale = open([a, b, c])
    _ = stale.key(.accept, issues: [a, b, c], writes: true)
    #expect(stale.issuesChanged([b, c], checked: true) == [])
    #expect(stale.finished(.replaced) == [.wait(a.id, .seconds(8))])
    var again = open([a, b, c])
    _ = again.key(.accept, issues: [a, b, c], writes: true)
    _ = again.issuesChanged([], checked: false)
    _ = again.issuesChanged([b.moved(to: 21)], checked: true)
    #expect(again.issuesChanged([], checked: false) == [])
    #expect(again.finished(.replaced) == [.wait(a.id, .seconds(8))])
}

@Test func aNewAcceptForgetsTheEarlierSuspension() {
    var mode = open([a, b, c])
    _ = mode.key(.accept, issues: [a, b, c], writes: true)
    _ = mode.finished(.replaced)
    _ = mode.issuesChanged([], checked: false)
    _ = mode.issuesChanged([b, c], checked: true)
    #expect(mode.key(.accept, issues: [b, c], writes: true) == [.accept(b.id)])
    _ = mode.finished(.replaced)
    #expect(mode.issuesChanged([c], checked: true) == [])             // the old list again
    #expect(mode.issuesChanged([], checked: false) == [])
    #expect(mode.issuesChanged([c], checked: true) == [.show(c.id)])
    var early = open([a, b, c])                                       // the same, with a recheck that came while applying
    _ = early.key(.accept, issues: [a, b, c], writes: true)
    _ = early.issuesChanged([], checked: false)
    _ = early.issuesChanged([b, c], checked: true)
    #expect(early.finished(.replaced) == [.show(b.id)])
    #expect(early.key(.accept, issues: [b, c], writes: true) == [.accept(b.id)])
    #expect(early.finished(.replaced) == [.wait(b.id, .seconds(8))])  // not a show from the earlier recheck's list
}

@Test func theRecheckFindingNothingEndsTheModeAndAnEarlierIssueIsShownWhenNoneFollows() {
    var last = open([a])
    _ = last.key(.accept, issues: [a], writes: true)
    _ = last.finished(.replaced)
    _ = last.issuesChanged([], checked: false)
    #expect(last.issuesChanged([], checked: true) == [.close])
    var back = open([a, b])
    _ = back.key(.next, issues: [a, b], writes: true)
    _ = back.key(.accept, issues: [a, b], writes: true)
    _ = back.finished(.replaced)
    _ = back.issuesChanged([], checked: false)
    #expect(back.issuesChanged([a], checked: true) == [.show(a.id)])
}

@Test func aRecheckThatNeverArrivesEndsTheModeAfterTheWait() {
    var mode = open([a, b])
    _ = mode.key(.accept, issues: [a, b], writes: true)
    _ = mode.finished(.replaced)
    #expect(mode.waitEnded(b.id) == [])
    #expect(mode.waitEnded(a.id) == [.close])
    #expect(!mode.holdsKeys)
}

@Test(arguments: [ReplaceOutcome.failed, .refusedChanged, .refusedOtherField, .unsupported, .clipboardBusy, .unconfirmed])
func aWriteThatIsNotConfirmedEndsTheMode(_ outcome: ReplaceOutcome) {
    var mode = open([a, b])
    _ = mode.key(.accept, issues: [a, b], writes: true)
    #expect(mode.finished(outcome) == [.close])
    #expect(!mode.holdsKeys)
}

@Test func escLeavesWhileAWriteIsAppliedAndWhileTheRecheckIsAwaited() {
    var applying = open([a])
    _ = applying.key(.accept, issues: [a], writes: true)
    #expect(applying.key(.leave, issues: [], writes: true) == [.close])
    #expect(applying.finished(.replaced) == [])
    var awaiting = open([a])
    _ = awaiting.key(.accept, issues: [a], writes: true)
    _ = awaiting.finished(.replaced)
    #expect(awaiting.key(.leave, issues: [], writes: true) == [.close])
    #expect(awaiting.issuesChanged([b], checked: true) == [])
}

@Test func withoutACleanWriteAcceptCopiesAndStays() {
    var mode = open([a, b])
    #expect(mode.key(.accept, issues: [a, b], writes: false) == [.copy(a.id)])
    #expect(mode.phase == .showing(a.id))
}

@Test func dismissMovesOn() {
    var mode = open([a, b])
    #expect(mode.key(.dismiss, issues: [a, b], writes: true) == [.dismiss(a.id), .show(b.id)])
    #expect(mode.key(.dismiss, issues: [b], writes: true) == [.dismiss(b.id), .close])
}

@Test func theShownIssueVanishingMovesToTheNearest() {
    var mode = open([a, b, c])
    _ = mode.key(.next, issues: [a, b, c], writes: true)             // on b, position 20
    #expect(mode.issuesChanged([a, c], checked: true) == [.show(c.id)])
    #expect(mode.issuesChanged([a], checked: true) == [.show(a.id)])
    #expect(mode.issuesChanged([], checked: false) == [.close])
}

@Test func theShownIssueMovingMovesThePositionWithIt() {
    var mode = open([a, b])
    #expect(mode.issuesChanged([a.moved(to: 9), b], checked: true) == [])
    #expect(mode.position == 9)
}

@Test func anEditWhileACardIsShownLeaves() {
    var mode = open([a, b])
    #expect(mode.edited() == [.close])
    #expect(!mode.holdsKeys)
}

@Test func everyWayOutClosesTheMode() {
    for leave: (inout ReviewMode) -> [ReviewMode.Effect] in [
        { $0.left() }, { $0.toggle(issues: [a]) }, { $0.key(.leave, issues: [a], writes: true) },
        { $0.issuesChanged([], checked: true) }, { $0.edited() },
    ] {
        var mode = open([a])
        #expect(leave(&mode) == [.close])
        #expect(mode.phase == .closed && !mode.holdsKeys)
        #expect(ReviewMode.Key.allCases.allSatisfy { mode.key($0, issues: [a], writes: true) == [] })
    }
}
