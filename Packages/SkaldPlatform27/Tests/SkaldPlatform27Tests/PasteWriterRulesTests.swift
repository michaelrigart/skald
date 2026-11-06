import AppKit
import Foundation
import SkaldCore
import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27
import struct SkaldCore.TextRange

// MARK: The paste plan

/// What each step of a paste write finds, scripted; lists answer successive calls and their last entry repeats.
private struct Script {
    var restorable = true
    var quiet: QuietPeriod.Outcome = .quiet(restarts: 0)
    var selection: PastePlan.SelectionStart = .requested
    var covered: [Bool] = [true]
    var staging: PasteboardSwap.Staging = .staged
    var recheck: PastePlan.RecheckPost = .posted(true)
    /// One per poll, 25 ms apart from the ⌘V on.
    var reads: [PastePlan.Read] = [.expected]
}

/// Every step the plan asks for, in order, until it finishes.
private func steps(_ script: Script) -> [PastePlan.Step] {
    var plan = PastePlan()
    var pending = plan.start()
    var taken: [PastePlan.Step] = []
    var checks = 0
    var polls = 0
    while !pending.isEmpty, taken.count < 1_000 {
        let step = pending.removeFirst()
        taken.append(step)
        let input: PastePlan.Input?
        switch step {
        case .snapshot: input = .clipboard(restorable: script.restorable)
        case .watchQuiet: input = .quiet(script.quiet)
        case .select: input = .selection(script.selection)
        case .checkSelection:
            input = .covered(script.covered[min(checks, script.covered.count - 1)], waited: .milliseconds(25 * checks))
            checks += 1
        case .stage: input = .staged(script.staging)
        case .recheckAndPost: input = .rechecked(script.recheck)
        case .poll:
            input = .read(script.reads[min(polls, script.reads.count - 1)], elapsed: .milliseconds(25 * polls))
            polls += 1
        default: input = nil
        }
        if let input { pending += plan.next(input) }
    }
    return taken
}

private func count(_ step: PastePlan.Step, in steps: [PastePlan.Step]) -> Int {
    steps.filter { $0 == step }.count
}

private func isPoll(_ step: PastePlan.Step) -> Bool {
    if case .poll = step { return true }
    return false
}

/// The steps taken once ⌘V was posted.
private func afterPost(_ steps: [PastePlan.Step]) -> [PastePlan.Step] {
    guard let post = steps.firstIndex(of: .recheckAndPost) else { return [] }
    return Array(steps[(post + 1)...])
}

@Test func aConfirmedPasteStagesPostsAndRestoresExactlyOnceInOrder() {
    #expect(steps(Script()) == [
        .snapshot, .watchQuiet, .select, .checkSelection(after: .zero), .stage, .recheckAndPost, .poll(after: .zero),
        .restoreClipboard, .restoreCaret(.confirmed), .finish(.replaced),
    ])
}

@Test func anUnrestorableClipboardIsUnsupportedBeforeAnythingIsTouched() {
    #expect(steps(Script(restorable: false)) == [.snapshot, .finish(.unsupported)])
}

@Test func aFieldOver20000UnitsIsUnsupportedWithNothingStaged() {
    #expect(steps(Script(quiet: .tooLong)) == [.snapshot, .watchQuiet, .finish(.unsupported)])
}

@Test func aClipboardChangedSinceTheSnapshotAbortsWithTheClipboardRestoredAndTheSelectionPutBack() {
    let taken = steps(Script(staging: .changedSinceSnapshot))
    #expect(Array(taken.suffix(3)) == [.restoreClipboard, .restoreCaret(.abortedAfterSelecting), .finish(.failed)])
    #expect(count(.recheckAndPost, in: taken) == 0)
}

@Test func theChecksBeforeSelectingRefuseWithoutStagingOrMovingTheSelection() {
    let changed = steps(Script(selection: .refused(.paragraphChanged)))
    #expect(changed == [.snapshot, .watchQuiet, .select, .finish(.refusedChanged)])
    for mismatch in [PastePlan.Mismatch.otherField, .notFrontmost] {
        #expect(steps(Script(selection: .refused(mismatch))) == [.snapshot, .watchQuiet, .select, .finish(.failed)])
    }
}

@Test func eachRecheckBeforeThePasteAbortsWithTheClipboardRestoredAndTheCaretRule() {
    for mismatch in [PastePlan.Mismatch.notFrontmost, .otherField, .selectionMoved] {
        let taken = steps(Script(recheck: .mismatch(mismatch)))
        #expect(Array(taken.suffix(4)) == [.recheckAndPost, .restoreClipboard, .restoreCaret(.abortedAfterSelecting), .finish(.failed)])
        #expect(!taken.contains(where: isPoll))
        #expect(count(.restoreClipboard, in: taken) == 1)
    }
}

@Test func aSelectionThatNeverCoversTheRangeAbortsAfterHalfASecond() {
    let taken = steps(Script(covered: [false]))
    #expect(taken.filter { if case .checkSelection = $0 { true } else { false } }.count == 21)
    #expect(Array(taken.suffix(2)) == [.restoreCaret(.abortedAfterSelecting), .finish(.failed)])
    #expect(count(.stage, in: taken) == 0)
}

@Test func aSelectionThatLandsLateIsWaitedFor() {
    let taken = steps(Script(covered: [false, false, true]))
    #expect(taken.last == .finish(.replaced))
    #expect(taken.contains(.checkSelection(after: .milliseconds(25))))
}

@Test func aRangeOutOfTheMarkersReachIsUnsupportedWithoutMovingTheSelection() {
    #expect(steps(Script(selection: .unreachable)) == [.snapshot, .watchQuiet, .select, .finish(.unsupported)])
    let rejected = steps(Script(selection: .rejected))
    #expect(Array(rejected.suffix(2)) == [.restoreCaret(.abortedAfterSelecting), .finish(.failed)])
}

@Test func theOriginalParagraphFirstAndTheExpectedOneHalfASecondLaterIsAConfirmedPaste() {
    let taken = steps(Script(reads: Array(repeating: .original, count: 20) + [.expected]))
    #expect(taken.filter(isPoll).count == 21)
    #expect(Array(taken.suffix(3)) == [.restoreClipboard, .restoreCaret(.confirmed), .finish(.replaced)])
}

@Test func aDifferentParagraphAfterThePasteIsUnconfirmedAndKeepsTheFix() {
    let after = afterPost(steps(Script(reads: [.other])))
    #expect(after == [.poll(after: .zero), .awaitProof, .finish(.unconfirmed)])
}

@Test func theOriginalParagraphForThreeSecondsIsUnconfirmedAndKeepsTheFix() {
    let after = afterPost(steps(Script(reads: [.original])))
    #expect(after.filter(isPoll).count == 121)
    #expect(Array(after.suffix(2)) == [.awaitProof, .finish(.unconfirmed)])
    #expect(count(.restoreClipboard, in: after) == 0)
}

@Test func noPathRestoresTheClipboardAfterThePasteWithoutTheExpectedParagraph() {
    let scripts: [[PastePlan.Read]] = [[.other], [.original], [.unreadable], [.original, .unreadable, .other], [.unreadable, .original]]
    for reads in scripts {
        let after = afterPost(steps(Script(reads: reads)))
        #expect(count(.restoreClipboard, in: after) == 0)
        #expect(after.last == .finish(.unconfirmed))
        #expect(!after.contains(.restoreCaret(.confirmed)))
        #expect(!after.contains(.restoreCaret(.abortedAfterSelecting)))
    }
}

@Test func keyEventsThatCannotBeCreatedAbortBeforeAnythingPastes() {
    let taken = steps(Script(recheck: .posted(false)))
    #expect(Array(taken.suffix(3)) == [.restoreClipboard, .restoreCaret(.abortedAfterSelecting), .finish(.failed)])
}

@Test func aCancelledWriteAbortsBeforeThePasteAndAwaitsProofAfterIt() {
    var early = PastePlan()
    _ = early.start()
    _ = early.next(.clipboard(restorable: true))
    #expect(early.next(.cancelled) == [.finish(.failed)])

    var late = PastePlan()
    for input: PastePlan.Input in [
        .clipboard(restorable: true), .quiet(.quiet(restarts: 0)), .selection(.requested), .covered(true, waited: .zero),
        .staged(.staged), .rechecked(.posted(true)),
    ] { _ = late.next(input) }
    #expect(late.next(.cancelled) == [.awaitProof, .finish(.unconfirmed)])
}

@Test func aWriteCancelledBetweenStagingAndThePasteRestoresTheClipboardAtOnce() {
    var plan = PastePlan()
    for input: PastePlan.Input in [
        .clipboard(restorable: true), .quiet(.quiet(restarts: 0)), .selection(.requested), .covered(true, waited: .zero), .staged(.staged),
    ] { _ = plan.next(input) }
    #expect(plan.next(.cancelled) == [.restoreClipboard, .restoreCaret(.abortedAfterSelecting), .finish(.failed)])
}

@Test func aClipboardCopiedOverRightBeforeThePasteAbortsAndIsLeftAlone() {
    var plan = PastePlan()
    for input: PastePlan.Input in [
        .clipboard(restorable: true), .quiet(.quiet(restarts: 0)), .selection(.requested), .covered(true, waited: .zero), .staged(.staged),
    ] { _ = plan.next(input) }
    #expect(plan.next(.clipboardChangedBeforePaste) == [.restoreCaret(.abortedAfterSelecting), .finish(.failed)])
    #expect(plan.abortReason == "the clipboard changed before the paste")
}

@Test func aReplacementThatEqualsTheTextAtTheRangeFailsBeforeTheSnapshot() {
    var plan = PastePlan(changesText: false)
    #expect(plan.start() == [.finish(.failed)])
    #expect(plan.next(.clipboard(restorable: true)) == [])
}

@Test func anEmptyReplacementFailsBeforeTheSnapshotAndStagesNothing() {
    var plan = PastePlan(hasText: false)
    #expect(plan.start() == [.finish(.failed)])
    #expect(plan.abortReason == "the replacement is empty")
    #expect(plan.next(.clipboard(restorable: true)) == [])
}

@Test func aFieldThatKeepsChangingFails() {
    #expect(steps(Script(quiet: .keptChanging)) == [.snapshot, .watchQuiet, .finish(.failed)])
}

@Test func nothingPastesTwiceAndAFinishedPlanTakesNoMoreSteps() {
    var plan = PastePlan()
    for input: PastePlan.Input in [
        .clipboard(restorable: true), .quiet(.quiet(restarts: 0)), .selection(.requested), .covered(true, waited: .zero),
    ] { _ = plan.next(input) }
    #expect(plan.next(.staged(.staged)) == [.recheckAndPost])
    #expect(plan.next(.staged(.staged)) == [])
    #expect(plan.next(.rechecked(.posted(true))) == [.poll(after: .zero)])
    #expect(plan.next(.rechecked(.posted(true))) == [])
    #expect(plan.next(.read(.expected, elapsed: .zero)).last == .finish(.replaced))
    #expect(plan.next(.read(.expected, elapsed: .zero)) == [])
    #expect(plan.next(.rechecked(.posted(true))) == [])
}

@Test func anAbortNamesAFixedKind() {
    var plan = PastePlan()
    _ = plan.next(.clipboard(restorable: true))
    _ = plan.next(.quiet(.quiet(restarts: 0)))
    _ = plan.next(.selection(.refused(.paragraphChanged)))
    #expect(plan.abortReason == "the paragraph changed")
}

// MARK: The paste's reads and the caret

private let original = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
private let revised = TextAccessRules.applying("are", at: TextRange(location: 5, length: 2), to: original)

private func read(_ text: String?) -> PastePlan.Read {
    TextAccessRules.pasteRead(
        original: original, revised: revised,
        read: { range in
            guard let text, range.end <= text.utf16.count else { return nil }
            return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
        },
        length: { text?.utf16.count }
    )
}

@Test func theFieldReadsTheExpectedTheOriginalOrAnotherParagraph() {
    #expect(read("They are ready.\nMore") == .expected)
    #expect(read("They is ready.\nMore") == .original)
    #expect(read("He is ready.\nMore") == .other)
    #expect(read("They are ready. More") == .other)
    #expect(read(nil) == .unreadable)
}

@Test func theSelectionCoversTheRangeOnlyWithItsExactText() {
    let range = TextRange(location: 5, length: 2)
    #expect(TextAccessRules.selectionCovers(range, text: "is", selection: range, selectedText: "is"))
    #expect(!TextAccessRules.selectionCovers(range, text: "is", selection: TextRange(location: 5, length: 3), selectedText: "is"))
    #expect(!TextAccessRules.selectionCovers(range, text: "is", selection: range, selectedText: "it"))
    #expect(!TextAccessRules.selectionCovers(range, text: "is", selection: range, selectedText: nil))
    #expect(!TextAccessRules.selectionCovers(range, text: "is", selection: nil, selectedText: "is"))
}

private let pasted = TextRange(location: 10, length: 4)

private func caret(_ end: WriteEnd, current: TextRange?, focused: Bool = true) -> TextRange? {
    TextAccessRules.pasteCaret(
        user: TextRange(location: 30, length: 0), replaced: pasted, replacementLength: 7, end: end, current: current, stillFocused: focused
    )
}

@Test func aConfirmedPastePutsTheCaretBackShiftedWhileTheCaretIsWhereThePasteLeftIt() {
    #expect(caret(.confirmed, current: TextRange(location: 17, length: 0)) == TextRange(location: 33, length: 0))
}

@Test func aPastesCaretIsLeftAloneWhenTheUserMovedItOrFocusLeft() {
    #expect(caret(.confirmed, current: TextRange(location: 2, length: 0)) == nil)
    #expect(caret(.confirmed, current: TextRange(location: 17, length: 0), focused: false) == nil)
    #expect(caret(.abortedAfterSelecting, current: TextRange(location: 2, length: 0)) == nil)
}

@Test func anAbortAfterSelectingPutsTheSelectionBackUnshiftedWhileTheRangeIsStillSelected() {
    #expect(caret(.abortedAfterSelecting, current: pasted) == TextRange(location: 30, length: 0))
}

@Test func anUnconfirmedPasteNeverMovesTheSelection() {
    #expect(caret(.unconfirmed, current: pasted) == nil)
    #expect(caret(.unconfirmed, current: TextRange(location: 17, length: 0)) == nil)
}

// MARK: The quiet interval

/// Waits for the clock's `count`th sleep; after 5 s of real time it gives up, so a regression fails instead of hanging.
private func sleeps(_ clock: TestClock, _ count: Int) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await clock.waitForSleepCalls(count)
            return !Task.isCancelled
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(5))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

/// The task's result; after 5 s of real time it is cancelled, which ends its clock sleeps, so a regression fails
/// instead of hanging.
private func value<T: Sendable>(of task: Task<T, Never>) async -> T {
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(5))
        task.cancel()
    }
    defer { watchdog.cancel() }
    return await task.value
}

private let slack = FieldID(app: "com.tinyspeck.slackmacgap", token: "1")

private final class Recorder<Value: Sendable>: @unchecked Sendable { // reason: values are only touched under the lock
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] { lock.withLock { stored } }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}

private func fieldState(_ text: String, caret: Int = 0) -> QuietPeriod.Read {
    .state(QuietPeriod.State(length: text.utf16.count, text: text, selection: TextRange(location: caret, length: 0)))
}

/// Watches `slack` on `clock`, recording the time of each state read.
private func watch(
    _ clock: TestClock, _ changes: ValueChanges, reads: Recorder<Duration>, state: @escaping @Sendable (Duration) -> QuietPeriod.Read
) -> Task<QuietPeriod.Outcome, Never> {
    let watcher = QuietWatch(field: slack, changes: changes, clock: PasteClock(clock))
    return Task {
        await watcher.run {
            let now = clock.now.offset
            reads.append(now)
            return state(now)
        }
    }
}

@Test func aQuietFieldPastesAfterOneAndAHalfSeconds() async throws {
    let clock = TestClock()
    let reads = Recorder<Duration>()
    let task = watch(clock, ValueChanges(), reads: reads) { _ in fieldState("They is ready.") }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: task) == .quiet(restarts: 0))
    #expect(reads.values == [.zero, .milliseconds(1500)])
}

@Test func aNotificationAtOneSecondMovesThePasteToTwoAndAHalfSeconds() async throws {
    let clock = TestClock()
    let changes = ValueChanges()
    let reads = Recorder<Duration>()
    let task = watch(clock, changes, reads: reads) { _ in fieldState("They is ready.") }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .seconds(1))
    changes.changed(FieldID(app: "com.tinyspeck.slackmacgap", token: "2"))
    changes.changed(slack)
    try #require(await sleeps(clock, 2))
    clock.advance(by: .milliseconds(500))
    clock.advance(by: .seconds(1))
    #expect(await value(of: task) == .quiet(restarts: 1))
    #expect(reads.values == [.zero, .seconds(1), .milliseconds(2500)])
}

@Test func anEditSeenOnlyAsAChangedLengthAtTheEndRestartsTheInterval() async throws {
    let clock = TestClock()
    let reads = Recorder<Duration>()
    let task = watch(clock, ValueChanges(), reads: reads) { now in
        now < .milliseconds(1400) ? fieldState("They is ready.\nMore") : fieldState("They is ready.\nMore!")
    }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(1500))
    try #require(await sleeps(clock, 2))
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: task) == .quiet(restarts: 1))
    #expect(reads.values == [.zero, .milliseconds(1500), .seconds(3)])
}

@Test func anEditSeenOnlyAsChangedTextOfTheSameLengthRestartsTheInterval() async throws {
    let clock = TestClock()
    let reads = Recorder<Duration>()
    let task = watch(clock, ValueChanges(), reads: reads) { now in
        now < .milliseconds(1400) ? fieldState("They is ready.\nMore") : fieldState("They is ready.\nMare")
    }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(1500))
    try #require(await sleeps(clock, 2))
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: task) == .quiet(restarts: 1))
}

@Test func aMovedSelectionRestartsTheInterval() async throws {
    let clock = TestClock()
    let reads = Recorder<Duration>()
    let task = watch(clock, ValueChanges(), reads: reads) { now in
        fieldState("They is ready.", caret: now < .seconds(1) ? 0 : 4)
    }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(1500))
    try #require(await sleeps(clock, 2))
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: task) == .quiet(restarts: 1))
}

@Test func aNotificationForAnEarlierEditDeliveredDuringTheIntervalRestartsIt() async throws {
    let clock = TestClock()
    let changes = ValueChanges()
    let reads = Recorder<Duration>()
    let task = watch(clock, changes, reads: reads) { _ in fieldState("They is ready!") }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(800))
    changes.changed(slack)
    try #require(await sleeps(clock, 2))
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: task) == .quiet(restarts: 1))
    #expect(reads.values == [.zero, .milliseconds(800), .milliseconds(2300)])
}

@Test func aNotificationEverySecondForTenSecondsGivesUp() async throws {
    let clock = TestClock()
    let changes = ValueChanges()
    let reads = Recorder<Duration>()
    let task = watch(clock, changes, reads: reads) { _ in fieldState("They is ready.") }
    for call in 1 ... 10 {
        try #require(await sleeps(clock, call))
        clock.advance(by: .seconds(1))
        changes.changed(slack)
    }
    #expect(await value(of: task) == .keptChanging)
    #expect(reads.values.last == .seconds(9))
    #expect(clock.wokenDeadlines.isEmpty)
}

@Test func aFieldOver20000UnitsCannotBeWatchedAndIsNeverWaitedOn() async {
    let clock = TestClock()
    let watcher = QuietWatch(field: slack, changes: ValueChanges(), clock: PasteClock(clock))
    #expect(await watcher.run { .tooLong } == .tooLong)
    #expect(clock.wokenDeadlines.isEmpty)
}

@Test func theQuietStateIsTheWholeFieldUpTo20000Units() {
    let selection = TextRange(location: 3, length: 0)
    func read(_ text: String, length: Int? = nil) -> QuietPeriod.Read {
        QuietPeriod.read(length: length ?? text.utf16.count, text: { _ in text }, selection: { selection })
    }
    let full = String(repeating: "a", count: 20_000)
    #expect(read(full) == .state(QuietPeriod.State(length: 20_000, text: full, selection: selection)))
    var asked = false
    #expect(QuietPeriod.read(length: 20_001, text: { _ in
        asked = true
        return nil
    }, selection: { selection }) == .tooLong)
    #expect(!asked)
    #expect(read("abc", length: 4) == .unreadable)
    #expect(QuietPeriod.read(length: nil, text: { _ in "" }, selection: { nil }) == .unreadable)
}

@Test func theIntervalHoldsOnlyForEqualStatesWithoutANotification() {
    let one = QuietPeriod.State(length: 3, text: "abc", selection: TextRange(location: 0, length: 0))
    let other = QuietPeriod.State(length: 3, text: "abd", selection: TextRange(location: 0, length: 0))
    #expect(QuietPeriod.holds(start: one, end: one, notified: false))
    #expect(!QuietPeriod.holds(start: one, end: one, notified: true))
    #expect(!QuietPeriod.holds(start: one, end: other, notified: false))
}

// MARK: The paste writer

/// The Accessibility side of a paste write, scripted.
private final class FakeTarget: PasteTarget, @unchecked Sendable { // reason: state is only touched under the lock
    private let lock = NSLock()
    private var _state: QuietPeriod.Read = fieldState("They is ready.")
    private var _read: @Sendable () -> PastePlan.Read = { .expected }
    private var _recheck: PastePlan.Mismatch?
    private var _changesText = true
    private var _onCovers: @Sendable () -> Void = {}
    private var _calls: [String] = []
    private var _posts = 0
    private var _carets: [WriteEnd] = []

    var stateAnswer: QuietPeriod.Read {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    var readAnswer: @Sendable () -> PastePlan.Read {
        get { lock.withLock { _read } }
        set { lock.withLock { _read = newValue } }
    }

    var recheckAnswer: PastePlan.Mismatch? {
        get { lock.withLock { _recheck } }
        set { lock.withLock { _recheck = newValue } }
    }

    var changesText: Bool {
        get { lock.withLock { _changesText } }
        set { lock.withLock { _changesText = newValue } }
    }

    /// Runs while the writer waits for `covers`, the last await before staging.
    var onCovers: @Sendable () -> Void {
        get { lock.withLock { _onCovers } }
        set { lock.withLock { _onCovers = newValue } }
    }

    var calls: [String] { lock.withLock { _calls } }
    var posts: Int { lock.withLock { _posts } }
    var carets: [WriteEnd] { lock.withLock { _carets } }

    private func record(_ call: String) {
        lock.withLock { _calls.append(call) }
    }

    func state() async -> QuietPeriod.Read {
        record("state")
        return stateAnswer
    }

    func select() async -> (start: PastePlan.SelectionStart, user: TextRange?) {
        record("select")
        return (.requested, TextRange(location: 30, length: 0))
    }

    func covers() async -> Bool {
        record("covers")
        onCovers()
        return true
    }

    func recheckAndPost(keyCode: CGKeyCode) async -> PastePlan.RecheckPost {
        record("recheckAndPost")
        if let mismatch = recheckAnswer { return .mismatch(mismatch) }
        lock.withLock { _posts += 1 }
        return .posted(true)
    }

    func read() async -> PastePlan.Read {
        record("read")
        return readAnswer()
    }

    func restoreCaret(_ end: WriteEnd, user: TextRange?) async {
        record("caret")
        lock.withLock { _carets.append(end) }
    }
}

@MainActor
private func clipboard(holding text: String, types: [NSPasteboard.PasteboardType] = []) -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.michaelrigart.skald.tests.\(UUID().uuidString)"))
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    for type in types { item.setData(Data(), forType: type) }
    pasteboard.writeObjects([item])
    return pasteboard
}

@MainActor
private func writer(_ clock: TestClock, _ pasteboard: NSPasteboard) -> PasteWriter {
    PasteWriter(clock: PasteClock(clock), changes: ValueChanges(), pasteboardName: pasteboard.name)
}

@MainActor
private func held(_ pasteboard: NSPasteboard) -> String? {
    pasteboard.string(forType: .string)
}

@MainActor @Test func aConfirmedPasteRestoresTheClipboardAndPutsTheCaretBack() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let target = FakeTarget()
    let paste = writer(clock, pasteboard)
    let write = Task { await paste.write("are", in: slack, target: target) }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: write) == .replaced)
    #expect(held(pasteboard) == "old content")
    #expect(target.posts == 1)
    #expect(target.carets == [.confirmed])
    #expect(target.calls == ["state", "state", "select", "covers", "recheckAndPost", "read", "caret"])
}

@MainActor @Test func thePasteIsConfirmedWhenTheExpectedParagraphAppearsHalfASecondAfterTheOriginal() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let target = FakeTarget()
    target.readAnswer = { clock.now.offset >= .seconds(2) ? .expected : .original }
    let paste = writer(clock, pasteboard)
    let write = Task { await paste.write("are", in: slack, target: target) }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(1500))
    for call in 2 ... 21 {
        try #require(await sleeps(clock, call))
        clock.advance(by: .milliseconds(25))
    }
    #expect(await value(of: write) == .replaced)
    #expect(held(pasteboard) == "old content")
    #expect(target.calls.filter { $0 == "read" }.count == 21)
}

/// Runs a write whose field keeps reading `read` after ⌘V until the 3 s bound.
@MainActor
private func unconfirmedWrite(_ clock: TestClock, _ paste: PasteWriter, _ target: FakeTarget) async throws -> ReplaceOutcome {
    let write = Task { await paste.write("are", in: slack, target: target) }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(1500))
    if target.readAnswer() == .original {
        for call in 2 ... 121 {
            try #require(await sleeps(clock, call))
            clock.advance(by: .milliseconds(25))
        }
    }
    return await value(of: write)
}

@MainActor @Test func aTimedOutPasteKeepsTheFixAndRestoresOnlyWhenTheFieldShowsIt() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let target = FakeTarget()
    target.readAnswer = { .original }
    let paste = writer(clock, pasteboard)
    #expect(try await unconfirmedWrite(clock, paste, target) == .unconfirmed)
    #expect(held(pasteboard) == "are")
    #expect(target.carets.isEmpty)

    #expect(await paste.fieldChanged(slack) == nil)
    clock.advance(by: .seconds(3600))
    #expect(held(pasteboard) == "are")
    #expect(await paste.fieldChanged(FieldID(app: "com.tinyspeck.slackmacgap", token: "2")) == nil)

    target.readAnswer = { .expected }
    #expect(await paste.fieldChanged(slack) == .restored)
    #expect(held(pasteboard) == "old content")
    #expect(target.carets.isEmpty)
    #expect(await paste.fieldChanged(slack) == nil)
}

@MainActor @Test func aPasteThatLandsOnAnotherParagraphKeepsTheFixUntilTheFieldShowsIt() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let target = FakeTarget()
    target.readAnswer = { .other }
    let paste = writer(clock, pasteboard)
    #expect(try await unconfirmedWrite(clock, paste, target) == .unconfirmed)
    #expect(held(pasteboard) == "are")
    target.readAnswer = { .expected }
    #expect(await paste.fieldChanged(slack) == .restored)
    #expect(held(pasteboard) == "old content")
}

@MainActor @Test func anUnconfirmedPasteLeavesANewerCopyAlone() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let target = FakeTarget()
    target.readAnswer = { .other }
    let paste = writer(clock, pasteboard)
    #expect(try await unconfirmedWrite(clock, paste, target) == .unconfirmed)
    pasteboard.clearContents()
    pasteboard.setString("copied since", forType: .string)
    target.readAnswer = { .expected }
    #expect(await paste.fieldChanged(slack) == .leftAlone)
    #expect(held(pasteboard) == "copied since")
    #expect(await paste.fieldChanged(slack) == nil)
}

@MainActor @Test func aSecondReplaceDuringAPasteWriteFails() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let paste = writer(clock, pasteboard)
    let first = Task { await paste.write("are", in: slack, target: FakeTarget()) }
    try #require(await sleeps(clock, 1))
    let second = FakeTarget()
    let refused = Task { await paste.write("is", in: FieldID(app: "com.tinyspeck.slackmacgap", token: "2"), target: second) }
    #expect(await value(of: refused) == .failed)
    #expect(second.calls.isEmpty)
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: first) == .replaced)
}

@MainActor @Test func anUnrestorableClipboardIsUnsupportedAndNothingIsTouched() async {
    let pasteboard = clipboard(holding: "a password", types: [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")])
    defer { pasteboard.releaseGlobally() }
    let before = pasteboard.changeCount
    let target = FakeTarget()
    #expect(await value(of: Task { await writer(TestClock(), pasteboard).write("are", in: slack, target: target) }) == .unsupported)
    #expect(target.calls.isEmpty)
    #expect(pasteboard.changeCount == before)
}

@MainActor @Test func aPasteIntoAFieldOver20000UnitsIsUnsupportedWithNothingStaged() async {
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let before = pasteboard.changeCount
    let target = FakeTarget()
    target.stateAnswer = .tooLong
    #expect(await value(of: Task { await writer(TestClock(), pasteboard).write("are", in: slack, target: target) }) == .unsupported)
    #expect(target.calls == ["state"])
    #expect(pasteboard.changeCount == before)
}

@MainActor @Test func aRecheckThatFailsBeforeThePasteRestoresTheClipboardAndTheSelection() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let target = FakeTarget()
    target.recheckAnswer = .notFrontmost
    let write = Task { await writer(clock, pasteboard).write("are", in: slack, target: target) }
    try #require(await sleeps(clock, 1))
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: write) == .failed)
    #expect(held(pasteboard) == "old content")
    #expect(target.posts == 0)
    #expect(target.carets == [.abortedAfterSelecting])
}

@MainActor @Test func theCommandVKeyCodeIsAKeyOnTheKeyboard() {
    #expect(CommandV.keyCode() < 128)
}

@MainActor @Test func aWriteCancelledAfterStagingRestoresTheClipboardAndNeverPastes() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let target = FakeTarget()
    let paste = writer(clock, pasteboard)
    let write = Task { await paste.write("are", in: slack, target: target) }
    try #require(await sleeps(clock, 1))
    target.onCovers = { write.cancel() }
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: write) == .failed)
    #expect(held(pasteboard) == "old content")
    #expect(!target.calls.contains("recheckAndPost"))
    #expect(target.carets == [.abortedAfterSelecting])
}

@MainActor @Test func anEmptyReplacementFailsWithNothingStaged() async {
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let before = pasteboard.changeCount
    let target = FakeTarget()
    #expect(await value(of: Task { await writer(TestClock(), pasteboard).write("", in: slack, target: target) }) == .failed)
    #expect(target.calls.isEmpty)
    #expect(pasteboard.changeCount == before)
    #expect(held(pasteboard) == "old content")
}

@MainActor @Test func aReplacementThatChangesNothingFailsWithNothingTouched() async {
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let before = pasteboard.changeCount
    let target = FakeTarget()
    target.changesText = false
    #expect(await value(of: Task { await writer(TestClock(), pasteboard).write("is", in: slack, target: target) }) == .failed)
    #expect(target.calls.isEmpty)
    #expect(pasteboard.changeCount == before)
}

@MainActor @Test func aFieldThatKeepsChangingForTenSecondsFailsAndFreesTheApp() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let paste = writer(clock, pasteboard)
    let busy = FakeTarget()
    busy.stateAnswer = fieldState("They is ready.")
    let changing = Task { await paste.write("are", in: slack, target: busy) }
    for call in 1 ... 7 {
        try #require(await sleeps(clock, call))
        busy.stateAnswer = fieldState("They is ready." + String(repeating: "!", count: call))
        clock.advance(by: .milliseconds(1500))
    }
    #expect(await value(of: changing) == .failed)
    #expect(clock.now.offset == .milliseconds(10_500))
    #expect(!busy.calls.contains("select"))
    #expect(held(pasteboard) == "old content")

    let next = Task { await paste.write("are", in: slack, target: FakeTarget()) }
    try #require(await sleeps(clock, 8))
    clock.advance(by: .milliseconds(1500))
    #expect(await value(of: next) == .replaced)
}

@MainActor @Test func anUnconfirmedPasteMakesTheNextPasteWriteUnsupported() async throws {
    let clock = TestClock()
    let pasteboard = clipboard(holding: "old content")
    defer { pasteboard.releaseGlobally() }
    let target = FakeTarget()
    target.readAnswer = { .other }
    let paste = writer(clock, pasteboard)
    #expect(try await unconfirmedWrite(clock, paste, target) == .unconfirmed)
    let next = FakeTarget()
    #expect(await value(of: Task { await paste.write("is", in: FieldID(app: "md.obsidian", token: "3"), target: next) }) == .unsupported)
    #expect(next.calls.isEmpty)
    #expect(held(pasteboard) == "are")
}
