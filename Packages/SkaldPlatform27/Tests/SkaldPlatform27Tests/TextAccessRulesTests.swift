import CoreGraphics
import Foundation
import SkaldCore
import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27
import struct SkaldCore.TextRange

/// A field held in memory, read through the same read decision as `RangeReader`.
private final class FakeField: FieldReader, @unchecked Sendable { // reason: each test touches it from one task at a time
    var text: String
    var selected: TextRange?
    var rangedReads = true
    var acceptsSelection = true
    var appliesWrites = true
    private(set) var valueReads = 0

    init(_ text: String, selected: TextRange? = TextRange(location: 0, length: 0)) {
        self.text = text
        self.selected = selected
    }

    func length() -> Int? { text.utf16.count }
    func selection() -> TextRange? { selected }

    func string(for range: TextRange) -> String? {
        TextAccessRules.read(
            range,
            ranged: { rangedReads && range.end <= text.utf16.count ? substring(range) : nil },
            length: { text.utf16.count },
            value: {
                valueReads += 1
                return text
            }
        )
    }

    func bounds(for range: TextRange) -> CGRect? { nil }

    func select(_ range: TextRange) -> Bool {
        guard acceptsSelection else { return false }
        selected = range
        return true
    }

    func setSelectedText(_ replacement: String) -> Bool {
        guard let selected else { return false }
        if appliesWrites {
            text = (text as NSString).replacingCharacters(in: NSRange(location: selected.location, length: selected.length), with: replacement)
        }
        self.selected = TextRange(location: selected.location + replacement.utf16.count, length: 0)
        return true
    }

    private func substring(_ range: TextRange) -> String {
        (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable { // reason: values are only touched under the lock
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] { lock.withLock { stored } }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}

private struct Node: Equatable {
    let id: Int
}

private let notes = FieldID(app: "com.apple.Notes", token: "1")

// MARK: Capabilities

@Test func notesAndTextEditWriteThroughAccessibilityWithEveryCapability() {
    for app in ["com.apple.Notes", "com.apple.TextEdit"] {
        let access = CapabilityTable.access(for: app)
        #expect(access.capabilities == [.read, .rangeBounds, .fieldFrame, .cleanWrite])
        #expect(access.write == .accessibility)
        #expect(access.mode == .native)
        #expect(access.probed.isEmpty)
    }
}

@Test func zenAndTheElectronAppsWriteByPaste() {
    let zen = CapabilityTable.access(for: "app.zen-browser.zen")
    #expect(zen.capabilities == [.read, .rangeBounds, .fieldFrame, .cleanWrite])
    #expect(zen.write == .paste)
    #expect(zen.mode == .firefox)
    for app in ["com.tinyspeck.slackmacgap", "org.whispersystems.signal-desktop", "md.obsidian"] {
        let access = CapabilityTable.access(for: app)
        #expect(access.capabilities == [.read, .fieldFrame, .cleanWrite])
        #expect(access.write == .paste)
        #expect(access.mode == .chromium)
    }
}

@Test func mailWritesByPasteAndProbesRangeBoundsAtRunTime() {
    let mail = CapabilityTable.access(for: "com.apple.mail")
    #expect(mail.capabilities == [.read, .fieldFrame, .cleanWrite])
    #expect(mail.probed == .rangeBounds)
    #expect(mail.write == .paste)
    #expect(mail.mode == .native)
    #expect(CapabilityTable.capabilities(mail, measured: [.rangeBounds]) == [.read, .rangeBounds, .fieldFrame, .cleanWrite])
    #expect(CapabilityTable.capabilities(mail, measured: []) == [.read, .fieldFrame, .cleanWrite])
}

@Test func protonMailIsReadOnly() {
    let proton = CapabilityTable.access(for: "ch.protonmail.desktop")
    #expect(proton.capabilities == [.read, .fieldFrame])
    #expect(proton.write == nil)
    #expect(proton.mode == .chromium)
}

@Test func anUnknownAppReadsAndProbesButNeverGetsACleanWrite() {
    let unknown = CapabilityTable.access(for: "com.example.editor")
    #expect(unknown.capabilities == [.read])
    #expect(unknown.probed == [.rangeBounds, .fieldFrame])
    #expect(unknown.write == nil)
    #expect(CapabilityTable.capabilities(unknown, measured: [.rangeBounds, .fieldFrame, .cleanWrite]) == [.read, .rangeBounds, .fieldFrame])
    #expect(CapabilityTable.capabilities(unknown, measured: [.fieldFrame]) == [.read, .fieldFrame])
    #expect(CapabilityTable.access(for: "com.google.Chrome").mode == .chromium)
}

@Test func aCleanWriteComesOnlyWithAWriteMethod() {
    let declared = AppAccess([.read, .cleanWrite], probed: [.cleanWrite, .rangeBounds], write: nil, mode: .native)
    #expect(declared.capabilities == [.read])
    #expect(declared.probed == [.rangeBounds])
    #expect(AppAccess([.read], write: .paste, mode: .native).capabilities == [.read, .cleanWrite])
}

@Test func theTableAgreesWithTheAccessibilityModeOfEveryKnownApp() {
    for (app, access) in CapabilityTable.known {
        #expect(access.mode == AppAccessibilityMode.forBundleID(app), "\(app)")
    }
}

// MARK: Replace decision

private let paragraph = ExpectedText(range: TextRange(location: 10, length: 13), text: "They is ready")
private let flagged = TextRange(location: 15, length: 2)

@Test func aCleanWriteAppGetsItsWriteMethod() {
    let notesStep = TextAccessRules.replaceStep(
        flagged, expected: paragraph, isFocusedField: true, currentText: { "They is ready" },
        access: CapabilityTable.access(for: "com.apple.Notes")
    )
    #expect(notesStep == .write(.accessibility))
    let slackStep = TextAccessRules.replaceStep(
        flagged, expected: paragraph, isFocusedField: true, currentText: { "They is ready" },
        access: CapabilityTable.access(for: "com.tinyspeck.slackmacgap")
    )
    #expect(slackStep == .write(.paste))
}

@Test func anotherFieldIsRefusedWithoutReadingIt() {
    let reads = Recorder<Int>()
    let step = TextAccessRules.replaceStep(
        flagged, expected: paragraph, isFocusedField: false,
        currentText: {
            reads.append(1)
            return "They is ready"
        },
        access: CapabilityTable.access(for: "com.apple.Notes")
    )
    #expect(step == .refuse(.refusedOtherField))
    #expect(reads.values.isEmpty)
}

@Test func identicalFlaggedWordsWithChangedSurroundingTextAreRefused() {
    let step = TextAccessRules.replaceStep(
        flagged, expected: paragraph, isFocusedField: true, currentText: { "Them is ready" },
        access: CapabilityTable.access(for: "com.apple.Notes")
    )
    #expect(step == .refuse(.refusedChanged))
    let unreadable = TextAccessRules.replaceStep(
        flagged, expected: paragraph, isFocusedField: true, currentText: { nil }, access: CapabilityTable.access(for: "com.apple.Notes")
    )
    #expect(unreadable == .refuse(.refusedChanged))
}

@Test func aReadOnlyOrUnknownAppIsUnsupported() {
    for app in ["ch.protonmail.desktop", "com.example.editor"] {
        let step = TextAccessRules.replaceStep(
            flagged, expected: paragraph, isFocusedField: true, currentText: { "They is ready" }, access: CapabilityTable.access(for: app)
        )
        #expect(step == .refuse(.unsupported), "\(app)")
    }
}

@Test func aRangeOutsideTheExpectedParagraphFails() {
    let step = TextAccessRules.replaceStep(
        TextRange(location: 20, length: 5), expected: paragraph, isFocusedField: true, currentText: { "They is ready" },
        access: CapabilityTable.access(for: "com.apple.Notes")
    )
    #expect(step == .refuse(.failed))
}

@Test func applyingAReplacementSplicesInUTF16Units() {
    let text = "👍🏽 Ik heb gedownloaded"
    let expected = ExpectedText(range: TextRange(location: 100, length: text.utf16.count), text: text)
    let word = TextRange(location: 100 + 12, length: 12)
    #expect((text as NSString).substring(with: NSRange(location: 12, length: 12)) == "gedownloaded")
    let revised = TextAccessRules.applying("gedownload", at: word, to: expected)
    #expect(revised.text == "👍🏽 Ik heb gedownload")
    #expect(revised.range == TextRange(location: 100, length: text.utf16.count - 2))
}

// MARK: Read decision

@Test func aRangedReadIsUsedWhenItAnswers() {
    let field = FakeField(String(repeating: "a", count: 30_000))
    #expect(field.string(for: TextRange(location: 100, length: 5)) == "aaaaa")
    #expect(field.valueReads == 0)
}

@Test func withoutRangedReadsAFieldOfAtMost20000UnitsIsReadWhole() {
    let field = FakeField(String(repeating: "a", count: 19_995) + "bcdef")
    field.rangedReads = false
    #expect(field.string(for: TextRange(location: 19_995, length: 5)) == "bcdef")
    #expect(field.valueReads == 1)
}

@Test func withoutRangedReadsALongerFieldGivesNothingAndItsValueIsNeverRead() {
    let field = FakeField(String(repeating: "a", count: 20_001))
    field.rangedReads = false
    #expect(field.string(for: TextRange(location: 0, length: 5)) == nil)
    #expect(field.valueReads == 0)
    #expect(TextAccessRules.snapshot(of: notes, reader: field) == nil)
}

@Test func aRangedReadOfTheWrongLengthIsNotTrusted() {
    let text = TextAccessRules.read(
        TextRange(location: 0, length: 5), ranged: { "abc" }, length: { 30_000 }, value: { nil }
    )
    #expect(text == nil)
}

@Test func aSnapshotReadsTheWindowAroundTheCaretOfALongField() {
    let field = FakeField(String(repeating: "a", count: 30_000) + "b" + String(repeating: "c", count: 29_999))
    field.selected = TextRange(location: 30_000, length: 0)
    let snapshot = TextAccessRules.snapshot(of: notes, reader: field)
    #expect(snapshot?.offset == 25_000)
    #expect(snapshot?.text.utf16.count == 10_000)
    #expect(snapshot?.totalLength == 60_000)
    #expect(snapshot?.selection == TextRange(location: 30_000, length: 0))
    #expect(field.valueReads == 0)
}

@Test func aFieldWithoutASelectionOrWithOneOutsideItGivesNoSnapshot() {
    #expect(TextAccessRules.snapshot(of: notes, reader: FakeField("Hello", selected: nil)) == nil)
    #expect(TextAccessRules.snapshot(of: notes, reader: FakeField("Hello", selected: TextRange(location: 4, length: 2))) == nil)
}

// MARK: Capture

@Test func anEmptySelectionCapturesTheCaretsParagraph() {
    let text = "First line.\n👍🏽 Ik heb het gedownloaded.\nLast."
    let field = FakeField(text, selected: TextRange(location: 20, length: 0))
    let capture = TextAccessRules.capture(of: notes, reader: field)
    let paragraph = TextRange(location: 12, length: "👍🏽 Ik heb het gedownloaded.".utf16.count)
    #expect(capture?.selection == paragraph)
    #expect(capture?.selectedText == "👍🏽 Ik heb het gedownloaded.")
    #expect(capture?.context == ExpectedText(range: paragraph, text: "👍🏽 Ik heb het gedownloaded."))
}

@Test func aSelectionKeepsItselfAndTakesTheParagraphsItOverlapsAsContext() {
    let text = "One two.\nThree four.\nFive."
    let field = FakeField(text, selected: TextRange(location: 4, length: 11))
    let capture = TextAccessRules.capture(of: notes, reader: field)
    #expect(capture?.selection == TextRange(location: 4, length: 11))
    #expect(capture?.selectedText == "two.\nThree ")
    #expect(capture?.context == ExpectedText(range: TextRange(location: 0, length: 20), text: "One two.\nThree four."))
}

@Test func aCaretOnAnEmptyLineCapturesNothingToReplace() {
    let field = FakeField("One.\n\nTwo.", selected: TextRange(location: 5, length: 0))
    let capture = TextAccessRules.capture(of: notes, reader: field)
    #expect(capture?.selection == TextRange(location: 5, length: 0))
    #expect(capture?.selectedText == "")
}

@Test func theCaptureWindowCoversALongSelectionInALongField() {
    let window = TextAccessRules.captureWindow(selection: TextRange(location: 20_000, length: 15_000), totalLength: 60_000)
    #expect(window == TextRange(location: 15_000, length: 25_000))
    #expect(TextAccessRules.captureWindow(selection: TextRange(location: 10, length: 5), totalLength: 20_000)
        == TextRange(location: 0, length: 20_000))
}

// MARK: The caret

private let replaced = TextRange(location: 10, length: 4)

@Test func aConfirmedWritePutsTheCaretBackShiftedOnlyWhenItLayAfterTheRange() {
    func target(_ caret: Int, length: Int = 0) -> TextRange? {
        TextAccessRules.caretTarget(
            user: TextRange(location: caret, length: length), replaced: replaced, replacementLength: 7, end: .confirmed
        )
    }
    #expect(target(3) == TextRange(location: 3, length: 0))
    #expect(target(10) == TextRange(location: 10, length: 0))
    #expect(target(12) == TextRange(location: 12, length: 0))
    #expect(target(14) == TextRange(location: 17, length: 0))
    #expect(target(30) == TextRange(location: 33, length: 0))
    #expect(target(5, length: 20) == TextRange(location: 5, length: 23))
}

@Test func aCaretInsideAShorterReplacementStaysInsideIt() {
    let target = TextAccessRules.caretTarget(
        user: TextRange(location: 13, length: 0), replaced: replaced, replacementLength: 1, end: .confirmed
    )
    #expect(target == TextRange(location: 11, length: 0))
}

@Test func anAbortAfterSelectingRestoresTheSelectionUnshifted() {
    let user = TextRange(location: 30, length: 0)
    #expect(TextAccessRules.caretTarget(user: user, replaced: replaced, replacementLength: 7, end: .abortedAfterSelecting) == user)
    #expect(TextAccessRules.caretTarget(user: user, replaced: replaced, replacementLength: 7, end: .abortedBeforeSelecting) == nil)
}

@Test func anUnconfirmedPasteNeverTouchesTheSelection() {
    let user = TextRange(location: 30, length: 0)
    #expect(TextAccessRules.caretTarget(user: user, replaced: replaced, replacementLength: 7, end: .unconfirmed) == nil)
}

@Test func theCaretIsLeftAloneWhenTheUserMovedItOrFocusLeft() {
    let left = TextRange(location: 17, length: 0)
    #expect(TextAccessRules.restoresCaret(stillFocused: true, current: left, left: left))
    #expect(!TextAccessRules.restoresCaret(stillFocused: true, current: TextRange(location: 2, length: 0), left: left))
    #expect(!TextAccessRules.restoresCaret(stillFocused: false, current: left, left: left))
    #expect(!TextAccessRules.restoresCaret(stillFocused: true, current: nil, left: left))
}

@Test func anAccessibilityWriteReplacesTheRangeAndPutsTheCaretBackShifted() {
    let field = FakeField("They is ready. More text", selected: TextRange(location: 20, length: 0))
    let expected = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
    let outcome = AccessibilityWrite.perform(
        TextRange(location: 5, length: 2), with: "are", expected: expected, reader: field,
        setSelectedText: field.setSelectedText, isFocused: { true }
    )
    #expect(outcome == .replaced)
    #expect(field.text == "They are ready. More text")
    #expect(field.selected == TextRange(location: 21, length: 0))
}

@Test func anAccessibilityWriteThatFailsRestoresTheSelectionUnshifted() {
    let field = FakeField("They is ready. More text", selected: TextRange(location: 20, length: 0))
    let expected = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
    let outcome = AccessibilityWrite.perform(
        TextRange(location: 5, length: 2), with: "are", expected: expected, reader: field,
        setSelectedText: { _ in false }, isFocused: { true }
    )
    #expect(outcome == .failed)
    #expect(field.selected == TextRange(location: 20, length: 0))
}

@Test func anAccessibilityWriteTheFieldDoesNotShowFails() {
    let field = FakeField("They is ready. More text", selected: TextRange(location: 20, length: 0))
    field.appliesWrites = false
    let expected = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
    let outcome = AccessibilityWrite.perform(
        TextRange(location: 5, length: 2), with: "are", expected: expected, reader: field,
        setSelectedText: field.setSelectedText, isFocused: { true }
    )
    #expect(outcome == .failed)
    #expect(field.selected == TextRange(location: 20, length: 0))
}

@Test func anAccessibilityWriteLeavesTheCaretWhereItIsOnceFocusLeft() {
    let field = FakeField("They is ready. More text", selected: TextRange(location: 20, length: 0))
    let expected = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
    let outcome = AccessibilityWrite.perform(
        TextRange(location: 5, length: 2), with: "are", expected: expected, reader: field,
        setSelectedText: field.setSelectedText, isFocused: { false }
    )
    #expect(outcome == .replaced)
    #expect(field.selected == TextRange(location: 8, length: 0))
}

// MARK: Focus

@Test func theFocusRetryDecisionRetriesAtOneThreeSixAndTenSeconds() {
    #expect(TextAccessRules.nextFocusRetry(afterAttempts: 1, outcome: .missing) == .seconds(1))
    #expect(TextAccessRules.nextFocusRetry(afterAttempts: 2, outcome: .missing) == .seconds(3))
    #expect(TextAccessRules.nextFocusRetry(afterAttempts: 3, outcome: .missing) == .seconds(6))
    #expect(TextAccessRules.nextFocusRetry(afterAttempts: 4, outcome: .missing) == .seconds(10))
    #expect(TextAccessRules.nextFocusRetry(afterAttempts: 5, outcome: .missing) == nil)
}

@Test func theFocusRetryDecisionStopsOnceTheElementAppearsOrFocusMoves() {
    #expect(TextAccessRules.nextFocusRetry(afterAttempts: 2, outcome: .found) == nil)
    #expect(TextAccessRules.nextFocusRetry(afterAttempts: 2, outcome: .moved) == nil)
}

@Test func aFailedQueryAtActivationIsRetriedAtOneThreeSixAndTenSeconds() async {
    let clock = TestClock()
    let retries = FocusRetries(clock: clock)
    let times = Recorder<Duration>()
    let task = retries.start {
        times.append(clock.now.offset)
        return .missing
    }
    for (calls, step) in [(1, 1), (2, 2), (3, 3), (4, 4)] {
        await clock.waitForSleepCalls(calls)
        clock.advance(by: .seconds(step))
    }
    await task.value
    #expect(times.values == [.seconds(1), .seconds(3), .seconds(6), .seconds(10)])
    #expect(clock.wokenDeadlines.map(\.offset) == [.seconds(1), .seconds(3), .seconds(6), .seconds(10)])
}

@Test func theRetriesEmitFocusedWhenTheElementAppearsAndStop() async {
    let clock = TestClock()
    let retries = FocusRetries(clock: clock)
    let events = Recorder<FieldEvent>()
    let times = Recorder<Duration>()
    let task = retries.start {
        times.append(clock.now.offset)
        guard clock.now.offset >= .seconds(3) else { return .missing }
        events.append(.focused(notes))
        return .found
    }
    await clock.waitForSleepCalls(1)
    clock.advance(by: .seconds(1))
    await clock.waitForSleepCalls(2)
    clock.advance(by: .seconds(2))
    await task.value
    clock.advance(by: .seconds(20))
    #expect(times.values == [.seconds(1), .seconds(3)])
    #expect(events.values == [.focused(notes)])
}

@Test func aFocusOrFrontmostChangeCancelsThePendingRetries() async {
    let clock = TestClock()
    let retries = FocusRetries(clock: clock)
    let times = Recorder<Duration>()
    let task = retries.start {
        times.append(clock.now.offset)
        return .missing
    }
    await clock.waitForSleepCalls(1)
    clock.advance(by: .seconds(1))
    await clock.waitForSleepCalls(2)
    retries.cancel()
    await task.value
    clock.advance(by: .seconds(20))
    #expect(times.values == [.seconds(1)])
}

@Test func aRetryThatSeesFocusMovedStops() async {
    let clock = TestClock()
    let retries = FocusRetries(clock: clock)
    let times = Recorder<Duration>()
    let task = retries.start {
        times.append(clock.now.offset)
        return .moved
    }
    await clock.waitForSleepCalls(1)
    clock.advance(by: .seconds(1))
    await task.value
    #expect(times.values == [.seconds(1)])
}

@Test func aNewActivationReplacesThePendingRetries() async {
    let clock = TestClock()
    let retries = FocusRetries(clock: clock)
    let first = Recorder<Duration>()
    let old = retries.start {
        first.append(clock.now.offset)
        return .missing
    }
    await clock.waitForSleepCalls(1)
    let new = retries.start { .found }
    await old.value
    await clock.waitForSleepCalls(2)
    clock.advance(by: .seconds(1))
    await new.value
    #expect(first.values.isEmpty)
}

@Test func aSecureFieldIsNoFieldAndIsNeverRead() {
    #expect(TextAccessRules.isSecure(role: "AXSecureTextField", subrole: nil))
    #expect(TextAccessRules.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
    var registry = FieldRegistry<Node, FakeField>(isSame: ==)
    let reads = Recorder<Int>()
    for (role, subrole) in [("AXSecureTextField", nil), ("AXTextField", "AXSecureTextField")] as [(String, String?)] {
        let candidate = TextAccessRules.isFieldCandidate(role: role, subrole: subrole, appEnabled: true)
        let id = registry.focus(Node(id: 1), app: "com.apple.Notes", isCandidate: candidate) {
            reads.append(1)
            return FakeField("secret")
        }
        #expect(FieldEvent.focused(id) == .focused(nil))
        #expect(registry.newest(app: "com.apple.Notes") == nil)
    }
    #expect(reads.values.isEmpty)
}

@Test func aDisabledAppOrAWebAreaIsNoField() {
    #expect(!TextAccessRules.isFieldCandidate(role: "AXTextArea", subrole: nil, appEnabled: false))
    #expect(!TextAccessRules.isFieldCandidate(role: "AXWebArea", subrole: nil, appEnabled: true))
    #expect(TextAccessRules.isFieldCandidate(role: "AXTextArea", subrole: nil, appEnabled: true))
}

@Test func theBoundsProbeUsesOneUnitAtTheCaret() {
    #expect(TextAccessRules.boundsProbeRange(selection: TextRange(location: 3, length: 0), totalLength: 10) == TextRange(location: 3, length: 1))
    #expect(TextAccessRules.boundsProbeRange(selection: TextRange(location: 10, length: 0), totalLength: 10) == TextRange(location: 9, length: 1))
    #expect(TextAccessRules.boundsProbeRange(selection: TextRange(location: 0, length: 0), totalLength: 0) == nil)
}

// MARK: Registry

@Test func theSameElementKeepsItsFieldAndItsSource() {
    var registry = FieldRegistry<Node, FakeField>(isSame: ==)
    let sources = Recorder<Int>()
    func focus(_ node: Node) -> FieldID? {
        registry.focus(node, app: "com.apple.Notes", isCandidate: true) {
            sources.append(node.id)
            return FakeField("Same text")
        }
    }
    let first = focus(Node(id: 1))
    #expect(focus(Node(id: 1)) == first)
    let twin = focus(Node(id: 2))
    #expect(twin != first)
    #expect(sources.values == [1, 2])
}

@Test func theRegistryKeepsTheNewestTwentyFields() {
    var registry = FieldRegistry<Node, FakeField>(isSame: ==)
    let ids = (0 ..< 21).compactMap { registry.focus(Node(id: $0), app: "com.apple.Notes", isCandidate: true) { FakeField("") } }
    #expect(ids.count == 21)
    #expect(registry.entry(ids[0]) == nil)
    #expect(registry.entry(ids[1])?.element == Node(id: 1))
    #expect(registry.newest(app: "com.apple.Notes")?.id == ids[20])
}

@Test func aFieldWithoutASourceIsNotRegistered() {
    var registry = FieldRegistry<Node, FakeField>(isSame: ==)
    #expect(registry.focus(Node(id: 1), app: "com.apple.mail", isCandidate: true) { nil } == nil)
    #expect(registry.newest(app: "com.apple.mail") == nil)
}

// MARK: Waiting for focus

@Test func aFocusWaitEndsWhenTheFieldIsFocusedAgain() async {
    let clock = TestClock()
    let waits = FocusWaits(clock: clock)
    let other = FieldID(app: "com.apple.Notes", token: "2")
    let waiting = Task { await waits.wait(for: notes, timeout: .seconds(1)) { false } }
    await clock.waitForSleepCalls(1)
    waits.focused(other)
    waits.focused(notes)
    #expect(await waiting.value)
}

@Test func aFocusWaitGivesUpAfterItsTimeout() async {
    let clock = TestClock()
    let waits = FocusWaits(clock: clock)
    let waiting = Task { await waits.wait(for: notes, timeout: .seconds(1)) { false } }
    await clock.waitForSleepCalls(1)
    clock.advance(by: .seconds(1))
    #expect(await !waiting.value)
}

@Test func aFieldAlreadyFocusedNeedsNoWait() async {
    let waits = FocusWaits(clock: TestClock())
    #expect(await waits.wait(for: notes, timeout: .seconds(1)) { true })
}
