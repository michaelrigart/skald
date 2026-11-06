import Foundation
import Testing
@testable import SkaldCore
import struct SkaldCore.TextRange

private let field = FieldID(app: "app", token: "a")
private let other = FieldID(app: "app", token: "b")
private let pause = Duration.milliseconds(700)

private func ms(_ value: Int) -> Duration { .milliseconds(value) }

private func snapshot(_ text: String, caret: Int = 0, field: FieldID = field) -> FieldSnapshot {
    FieldSnapshot(
        field: field,
        text: text,
        offset: 0,
        selection: TextRange(location: caret, length: 0),
        totalLength: text.utf16.count
    )
}

private func key(_ text: String, _ occurrence: Int = 0, chunk: Int = 0) -> ParagraphKey {
    ParagraphKey(field: field, text: text, position: .occurrence(occurrence), chunk: chunk)
}

private func whole(_ text: String) -> Paragraph {
    Paragraph(range: TextRange(location: 0, length: text.utf16.count), text: text)
}

private let longText = (0..<10).map { _ in String(repeating: "x", count: 298) + ". " }.joined()
private let longParagraph = whole(longText)
private let longChunks = Paragraphs.chunks(longParagraph)

private func chunkKey(_ index: Int) -> ParagraphKey { key(longText, chunk: index) }

private func spelling(_ index: Int) -> SchedulerEffect {
    .checkSpelling(chunkKey(index), chunk: longChunks[index], parent: longParagraph)
}

private func model(_ index: Int, _ generation: Int) -> SchedulerEffect {
    .checkModel(chunkKey(index), chunk: longChunks[index], parent: longParagraph, generation: generation)
}

private func focusedScheduler() -> CheckScheduler {
    var scheduler = CheckScheduler()
    _ = scheduler.handle(.field(.focused(field)), at: ms(0))
    return scheduler
}

@Test func focusingAFieldDisarmsAndArmsTheTimer() {
    var scheduler = CheckScheduler()
    #expect(scheduler.handle(.field(.focused(field)), at: ms(0)) == [.disarmTimer, .armTimer(deadline: pause)])
    #expect(scheduler.handle(.field(.focused(nil)), at: ms(50)) == [.disarmTimer])
}

@Test func anEditArmsTheTimerAndSuspendsIssues() {
    var scheduler = focusedScheduler()
    #expect(scheduler.handle(.field(.edited(field)), at: ms(0)) == [.suspendIssues(field), .armTimer(deadline: ms(700))])
}

@Test func aLaterEditRearmsTheTimerFromItsOwnTime() {
    var scheduler = focusedScheduler()
    _ = scheduler.handle(.field(.edited(field)), at: ms(0))
    #expect(scheduler.handle(.field(.edited(field)), at: ms(300)) == [.suspendIssues(field), .armTimer(deadline: ms(1000))])
}

@Test func caretMovesArmTheTimer() {
    var scheduler = focusedScheduler()
    #expect(scheduler.handle(.field(.caretMoved(field)), at: ms(100)) == [.armTimer(deadline: ms(800))])
}

@Test func aBurstOfTenEditsCostsOneRead() {
    var scheduler = focusedScheduler()
    var effects: [SchedulerEffect] = []
    for i in 0..<10 {
        effects += scheduler.handle(.field(.edited(field)), at: ms(i * 50))
    }
    #expect(!effects.contains(.read(field)))
    #expect(scheduler.handle(.timerFired, at: ms(1150)) == [.read(field)])
}

@Test func timerFiringWithoutAFieldEmitsNothing() {
    var scheduler = CheckScheduler()
    #expect(scheduler.handle(.timerFired, at: ms(0)).isEmpty)
    _ = scheduler.handle(.field(.focused(field)), at: ms(0))
    _ = scheduler.handle(.field(.focused(nil)), at: ms(10))
    #expect(scheduler.handle(.timerFired, at: ms(20)).isEmpty)
}

@Test func aRereadArmsThePauseForTheFocusedFieldOnly() {
    var scheduler = CheckScheduler()
    #expect(scheduler.handle(.reread, at: ms(0)).isEmpty)
    _ = scheduler.handle(.field(.focused(field)), at: ms(0))
    #expect(scheduler.handle(.reread, at: ms(300)) == [.armTimer(deadline: ms(300) + pause)])
    _ = scheduler.handle(.paused, at: ms(400))
    #expect(scheduler.handle(.reread, at: ms(500)).isEmpty)
}

@Test func eventsForAnotherFieldAreIgnored() {
    var scheduler = focusedScheduler()
    #expect(scheduler.handle(.field(.edited(other)), at: ms(0)).isEmpty)
    #expect(scheduler.handle(.field(.caretMoved(other)), at: ms(0)).isEmpty)
    #expect(scheduler.handle(.snapshot(snapshot("They is ready", field: other)), at: ms(0)).isEmpty)
}

@Test func aSnapshotRevalidatesThenChecksSpellingAndModel() {
    var scheduler = focusedScheduler()
    let s = snapshot("They is ready", caret: 4)
    let paragraph = whole("They is ready")
    #expect(scheduler.handle(.snapshot(s), at: ms(700)) == [
        .revalidate(s),
        .checkSpelling(key("They is ready"), chunk: paragraph, parent: paragraph),
        .checkModel(key("They is ready"), chunk: paragraph, parent: paragraph, generation: 1),
    ])
}

@Test func anUnchangedParagraphAfterTheModelFinishedEmitsOnlyRevalidate() {
    var scheduler = focusedScheduler()
    let s = snapshot("They is ready", caret: 4)
    _ = scheduler.handle(.snapshot(s), at: ms(700))
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(900)).isEmpty)
    #expect(scheduler.handle(.snapshot(s), at: ms(1600)) == [.revalidate(s)])
}

@Test func aSnapshotWhoseCaretHasNoParagraphEmitsOnlyRevalidate() {
    var scheduler = focusedScheduler()
    let s = snapshot("", caret: 0)
    #expect(scheduler.handle(.snapshot(s), at: ms(700)) == [.revalidate(s)])
}

@Test func theSameParagraphWhileItsCheckRunsKeepsTheCheck() {
    var scheduler = focusedScheduler()
    let s = snapshot("They is ready", caret: 4)
    _ = scheduler.handle(.snapshot(s), at: ms(700))
    #expect(scheduler.handle(.snapshot(s), at: ms(1500)) == [.revalidate(s)])
}

@Test func aThreeChunkParagraphChecksSpellingForAllAndTheModelForTheFirst() {
    #expect(longChunks.count == 3)
    var scheduler = focusedScheduler()
    let s = snapshot(longText, caret: 10)
    #expect(scheduler.handle(.snapshot(s), at: ms(700)) == [
        .revalidate(s), spelling(0), spelling(1), spelling(2), model(0, 1),
    ])
}

@Test func finishedChunksAdvanceTheQueueInOrder() {
    var scheduler = focusedScheduler()
    _ = scheduler.handle(.snapshot(snapshot(longText, caret: 10)), at: ms(700))
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(800)) == [model(1, 2)])
    #expect(scheduler.handle(.modelFinished(generation: 2), at: ms(900)) == [model(2, 3)])
    #expect(scheduler.handle(.modelFinished(generation: 3), at: ms(1000)).isEmpty)
}

@Test func aFailedChunkAdvancesWithoutBeingRemembered() {
    var scheduler = focusedScheduler()
    let s = snapshot(longText, caret: 10)
    _ = scheduler.handle(.snapshot(s), at: ms(700))
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(800)) == [model(1, 2)])
    #expect(scheduler.handle(.modelFailed(generation: 2), at: ms(900)) == [model(2, 3)])
    #expect(scheduler.handle(.modelFinished(generation: 3), at: ms(1000)).isEmpty)
    #expect(scheduler.handle(.snapshot(s), at: ms(1700)) == [.revalidate(s), model(1, 4)])
}

@Test func aDifferentCaretParagraphCancelsTheRunningCheckAndStartsTheNewOne() {
    var scheduler = focusedScheduler()
    let text = longText + "\nsecond"
    _ = scheduler.handle(.snapshot(snapshot(text, caret: 10)), at: ms(700))
    let moved = snapshot(text, caret: text.utf16.count)
    let secondParagraph = Paragraph(range: TextRange(location: longText.utf16.count + 1, length: 6), text: "second")
    #expect(scheduler.handle(.snapshot(moved), at: ms(1500)) == [
        .revalidate(moved),
        .checkSpelling(key("second"), chunk: secondParagraph, parent: secondParagraph),
        .cancelModel(generation: 1),
        .checkModel(key("second"), chunk: secondParagraph, parent: secondParagraph, generation: 2),
    ])
}

@Test func aRepeatedTextIsCheckedInItsOwnOccurrence() {
    var scheduler = focusedScheduler()
    let text = "They is ready\nok\nThey is ready"
    _ = scheduler.handle(.snapshot(snapshot(text, caret: 4)), at: ms(700))
    _ = scheduler.handle(.modelFinished(generation: 1), at: ms(800))
    let moved = snapshot(text, caret: 20)
    let paragraph = Paragraph(range: TextRange(location: 17, length: 13), text: "They is ready")
    #expect(scheduler.handle(.snapshot(moved), at: ms(1500)) == [
        .revalidate(moved),
        .checkSpelling(key("They is ready", 1), chunk: paragraph, parent: paragraph),
        .checkModel(key("They is ready", 1), chunk: paragraph, parent: paragraph, generation: 2),
    ])
}

@Test func focusingAnotherFieldCancelsTheRunningCheckAndClearsTheQueue() {
    var scheduler = focusedScheduler()
    _ = scheduler.handle(.snapshot(snapshot(longText, caret: 10)), at: ms(700))
    #expect(scheduler.handle(.field(.focused(other)), at: ms(800)) == [
        .disarmTimer, .cancelModel(generation: 1), .armTimer(deadline: ms(1500)),
    ])
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(900)).isEmpty)
}

@Test func pausingStopsEverythingAndIgnoresEventsUntilResumed() {
    var scheduler = focusedScheduler()
    let s = snapshot(longText, caret: 10)
    _ = scheduler.handle(.snapshot(s), at: ms(700))
    #expect(scheduler.handle(.paused, at: ms(800)) == [.disarmTimer, .cancelModel(generation: 1), .clearIssues])
    #expect(scheduler.handle(.field(.edited(field)), at: ms(900)).isEmpty)
    #expect(scheduler.handle(.field(.caretMoved(field)), at: ms(900)).isEmpty)
    #expect(scheduler.handle(.timerFired, at: ms(900)).isEmpty)
    #expect(scheduler.handle(.snapshot(s), at: ms(900)).isEmpty)
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(900)).isEmpty)
    #expect(scheduler.handle(.recheck, at: ms(900)).isEmpty)
    #expect(scheduler.handle(.resumed, at: ms(1000)) == [.armTimer(deadline: ms(1700))])
    #expect(scheduler.handle(.snapshot(s), at: ms(1700)) == [
        .revalidate(s), spelling(0), spelling(1), spelling(2), model(0, 2),
    ])
}

@Test func pausingWithoutARunningCheckSkipsTheCancel() {
    var scheduler = focusedScheduler()
    #expect(scheduler.handle(.paused, at: ms(0)) == [.disarmTimer, .clearIssues])
}

@Test func focusWhilePausedOnlyTracksTheField() {
    var scheduler = focusedScheduler()
    _ = scheduler.handle(.paused, at: ms(0))
    #expect(scheduler.handle(.field(.focused(other)), at: ms(10)).isEmpty)
    _ = scheduler.handle(.resumed, at: ms(20))
    #expect(scheduler.handle(.timerFired, at: ms(720)) == [.read(other)])
}

@Test func recheckCancelsClearsAndRearmsThenChecksARememberedParagraphAgain() {
    var scheduler = focusedScheduler()
    let s = snapshot("They is ready", caret: 4)
    let paragraph = whole("They is ready")
    _ = scheduler.handle(.snapshot(s), at: ms(700))
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(800)).isEmpty)
    #expect(scheduler.handle(.recheck, at: ms(1000)) == [.clearIssues, .armTimer(deadline: ms(1700))])
    #expect(scheduler.handle(.snapshot(s), at: ms(1700)) == [
        .revalidate(s),
        .checkSpelling(key("They is ready"), chunk: paragraph, parent: paragraph),
        .checkModel(key("They is ready"), chunk: paragraph, parent: paragraph, generation: 2),
    ])
}

@Test func recheckWithARunningCheckCancelsItBeforeClearing() {
    var scheduler = focusedScheduler()
    _ = scheduler.handle(.snapshot(snapshot(longText, caret: 10)), at: ms(700))
    #expect(scheduler.handle(.recheck, at: ms(1000)) == [
        .cancelModel(generation: 1), .clearIssues, .armTimer(deadline: ms(1700)),
    ])
}

@Test func aStaleFailureAfterTheNewCheckStartedChangesNothing() {
    var scheduler = focusedScheduler()
    let text = longText + "\nsecond"
    _ = scheduler.handle(.snapshot(snapshot(text, caret: 10)), at: ms(700))
    _ = scheduler.handle(.snapshot(snapshot(text, caret: text.utf16.count)), at: ms(1500))
    #expect(scheduler.handle(.modelFailed(generation: 1), at: ms(1600)).isEmpty)
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(1600)).isEmpty)
    #expect(scheduler.handle(.modelFinished(generation: 2), at: ms(1700)).isEmpty)
}

@Test func aStaleFailureLeavesTheQueueAsItWas() {
    var scheduler = focusedScheduler()
    _ = scheduler.handle(.snapshot(snapshot(longText, caret: 10)), at: ms(700))
    #expect(scheduler.handle(.modelFailed(generation: 9), at: ms(800)).isEmpty)
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(900)) == [model(1, 2)])
}

@Test func aLateFinishFromBeforeRecheckIsIgnored() {
    var scheduler = focusedScheduler()
    let s = snapshot("They is ready", caret: 4)
    _ = scheduler.handle(.snapshot(s), at: ms(700))
    _ = scheduler.handle(.recheck, at: ms(800))
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(900)).isEmpty)
    let paragraph = whole("They is ready")
    #expect(scheduler.handle(.snapshot(s), at: ms(1500)) == [
        .revalidate(s),
        .checkSpelling(key("They is ready"), chunk: paragraph, parent: paragraph),
        .checkModel(key("They is ready"), chunk: paragraph, parent: paragraph, generation: 2),
    ])
}

@Test func forgettingARememberedKeyChecksItAgain() {
    var scheduler = focusedScheduler()
    let s = snapshot("They is ready", caret: 4)
    let paragraph = whole("They is ready")
    _ = scheduler.handle(.snapshot(s), at: ms(700))
    _ = scheduler.handle(.modelFinished(generation: 1), at: ms(800))
    #expect(scheduler.handle(.forget([key("They is ready")]), at: ms(900)).isEmpty)
    #expect(scheduler.handle(.snapshot(s), at: ms(1600)) == [
        .revalidate(s),
        .checkSpelling(key("They is ready"), chunk: paragraph, parent: paragraph),
        .checkModel(key("They is ready"), chunk: paragraph, parent: paragraph, generation: 2),
    ])
}

@Test func onlyTheNewestRememberedKeysAreKept() {
    var scheduler = CheckScheduler(remember: 2)
    _ = scheduler.handle(.field(.focused(field)), at: ms(0))
    let text = "one\ntwo\nthree"
    var generation = 0
    for caret in [0, 4, 8] {
        _ = scheduler.handle(.snapshot(snapshot(text, caret: caret)), at: ms(0))
        generation += 1
        _ = scheduler.handle(.modelFinished(generation: generation), at: ms(0))
    }
    let one = whole("one")
    #expect(scheduler.handle(.snapshot(snapshot(text, caret: 0)), at: ms(0)) == [
        .revalidate(snapshot(text, caret: 0)),
        .checkSpelling(key("one"), chunk: one, parent: one),
        .checkModel(key("one"), chunk: one, parent: one, generation: 4),
    ])
    #expect(scheduler.handle(.snapshot(snapshot(text, caret: 8)), at: ms(0)) == [
        .revalidate(snapshot(text, caret: 8)),
        .cancelModel(generation: 4),
    ])
}

@Test func aCancelledGenerationNeverTouchesTheCheckThatReplacedIt() {
    var scheduler = focusedScheduler()
    let text = "They is ready\n" + longText
    let parent = Paragraph(range: TextRange(location: 14, length: longText.utf16.count), text: longText)
    let chunks = Paragraphs.chunks(parent)
    func chunkModel(_ index: Int, _ generation: Int) -> SchedulerEffect {
        .checkModel(chunkKey(index), chunk: chunks[index], parent: parent, generation: generation)
    }
    _ = scheduler.handle(.snapshot(snapshot(text, caret: 4)), at: ms(700))
    let moved = snapshot(text, caret: 20)
    let effects = scheduler.handle(.snapshot(moved), at: ms(1500))
    #expect(effects.first == .revalidate(moved))
    #expect(effects.suffix(2) == [.cancelModel(generation: 1), chunkModel(0, 2)])
    #expect(scheduler.handle(.modelFailed(generation: 1), at: ms(1600)).isEmpty)
    #expect(scheduler.handle(.modelFinished(generation: 1), at: ms(1600)).isEmpty)
    #expect(scheduler.handle(.modelFinished(generation: 2), at: ms(1700)) == [chunkModel(1, 3)])
}

@Test func theCaretIsReadInFieldCoordinatesInAWindowedSnapshot() {
    var scheduler = focusedScheduler()
    let s = FieldSnapshot(
        field: field,
        text: "alpha beta\ngamma",
        offset: 15_000,
        selection: TextRange(location: 15_013, length: 0),
        totalLength: 30_000
    )
    let paragraph = Paragraph(range: TextRange(location: 15_011, length: 5), text: "gamma")
    let windowed = ParagraphKey(field: field, text: "gamma", position: .location(15_011), chunk: 0)
    #expect(scheduler.handle(.snapshot(s), at: ms(700)) == [
        .revalidate(s),
        .checkSpelling(windowed, chunk: paragraph, parent: paragraph),
        .checkModel(windowed, chunk: paragraph, parent: paragraph, generation: 1),
    ])
}

@Test func focusingAFieldRespellsButDoesNotRemodelAnUnchangedParagraph() {
    var scheduler = focusedScheduler()
    let s = snapshot("They is ready", caret: 4)
    let paragraph = whole("They is ready")
    _ = scheduler.handle(.snapshot(s), at: ms(700))
    _ = scheduler.handle(.modelFinished(generation: 1), at: ms(800))
    _ = scheduler.handle(.field(.focused(other)), at: ms(900))
    _ = scheduler.handle(.field(.focused(field)), at: ms(1000))
    #expect(scheduler.handle(.snapshot(s), at: ms(1700)) == [
        .revalidate(s),
        .checkSpelling(key("They is ready"), chunk: paragraph, parent: paragraph),
    ])
}
