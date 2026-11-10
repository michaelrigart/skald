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
    /// Where the selection is by the time anyone reads it after `select`: the user moved the caret in between.
    var userMovesSelectionTo: TextRange?
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
        selected = userMovesSelectionTo ?? range
        userMovesSelectionTo = nil
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

@Test func mailWritesByPasteWithTheBadgeAndProbesNothing() {
    let mail = CapabilityTable.access(for: "com.apple.mail")
    #expect(mail.capabilities == [.read, .fieldFrame, .cleanWrite])
    #expect(mail.probed.isEmpty)
    #expect(mail.write == .paste)
    #expect(mail.mode == .native)
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

/// "They is ready" as the second line of "Hello\nThey is ready\nBye", with "is" flagged.
private let paragraph = ExpectedText(range: TextRange(location: 6, length: 13), text: "They is ready")
private let flagged = TextRange(location: 11, length: 2)

private func decide(
    _ text: String, in app: String = "com.apple.Notes", range: TextRange = flagged, focused: Bool = true
) -> ReplaceStep {
    let field = FakeField(text)
    return TextAccessRules.replaceStep(
        range, expected: paragraph, isFocusedField: focused, read: field.string(for:), length: field.length,
        access: CapabilityTable.access(for: app)
    )
}

@Test func aCleanWriteAppGetsItsWriteMethod() {
    #expect(decide("Hello\nThey is ready\nBye") == .write(.accessibility))
    #expect(decide("Hello\nThey is ready\nBye", in: "com.tinyspeck.slackmacgap") == .write(.paste))
}

@Test func anotherFieldIsRefusedWithoutReadingIt() {
    let reads = Recorder<TextRange>()
    let step = TextAccessRules.replaceStep(
        flagged, expected: paragraph, isFocusedField: false,
        read: {
            reads.append($0)
            return nil
        },
        length: { 23 }, access: CapabilityTable.access(for: "com.apple.Notes")
    )
    #expect(step == .refuse(.refusedOtherField))
    #expect(reads.values.isEmpty)
}

@Test func identicalFlaggedWordsWithChangedSurroundingTextAreRefused() {
    #expect(decide("Hello\nThem is ready\nBye") == .refuse(.refusedChanged))
    let unreadable = TextAccessRules.replaceStep(
        flagged, expected: paragraph, isFocusedField: true, read: { _ in nil }, length: { 23 },
        access: CapabilityTable.access(for: "com.apple.Notes")
    )
    #expect(unreadable == .refuse(.refusedChanged))
}

@Test func textTypedOnTheParagraphsLineAfterItsEndIsAChange() {
    #expect(decide("Hello\nThey is ready now\nBye") == .refuse(.refusedChanged))
    #expect(decide("Hello\nThey is ready.") == .refuse(.refusedChanged))
}

@Test func aRemovedLineBreakBeforeOrAfterTheParagraphIsAChange() {
    #expect(decide("Hello They is ready\nBye") == .refuse(.refusedChanged))
    #expect(decide("Hello\nThey is readyBye!") == .refuse(.refusedChanged))
}

@Test func aParagraphAtTheFieldsEdgesOrBetweenAnyLineBreaksIsUnchanged() {
    #expect(decide("Hello\nThey is ready") == .write(.accessibility))
    #expect(decide("Hello\u{2029}They is ready\r\nBye") == .write(.accessibility))
    let first = ExpectedText(range: TextRange(location: 0, length: 5), text: "Hello")
    let field = FakeField("Hello\nThey is ready")
    #expect(TextAccessRules.paragraphUnchanged(first, read: field.string(for:), length: field.length))
}

@Test func aReplacementChangesTheTextUnlessItHasTheSameUTF16UnitsAsTheRange() {
    let original = ExpectedText(range: TextRange(location: 10, length: 14), text: "They is ready.")
    let is_ = TextRange(location: 15, length: 2)
    #expect(!TextAccessRules.changesText(original, at: is_, replacement: "is"))
    #expect(TextAccessRules.changesText(original, at: is_, replacement: "are"))
    #expect(TextAccessRules.changesText(original, at: TextRange(location: 0, length: 2), replacement: "is"))

    let angstrom = ExpectedText(range: TextRange(location: 0, length: 1), text: "\u{212B}")
    let whole = TextRange(location: 0, length: 1)
    #expect("\u{212B}" == "\u{C5}")
    #expect(!TextAccessRules.changesText(angstrom, at: whole, replacement: "\u{212B}"))
    #expect(TextAccessRules.changesText(angstrom, at: whole, replacement: "\u{C5}"))
}

// MARK: The recheck in the job that posts ⌘V

private let checked = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
private let isRange = TextRange(location: 5, length: 2)

/// The posting job on `field`, with what it asked and did, in order.
private func recheck(
    _ field: FakeField, frontmost: Bool = true, focused: Bool = true, held: Bool = true
) -> (result: PastePlan.RecheckPost, ran: [String]) {
    var ran: [String] = []
    let result = TextAccessRules.recheck(
        isFrontmost: { ran.append("frontmost"); return frontmost },
        isFocusedElement: { ran.append("focused"); return focused },
        reader: field, original: checked, range: isRange,
        clipboardHeld: { ran.append("clipboard"); return held },
        post: { ran.append("post"); return true }
    )
    return (result, ran)
}

@Test func theClipboardIsTheLastCheckRightBeforeThePost() {
    let outcome = recheck(FakeField("They is ready.", selected: isRange))
    #expect(outcome.result == .posted(true))
    #expect(outcome.ran == ["frontmost", "focused", "clipboard", "post"])
}

@Test func aParagraphChangedAfterTheSelectionWasValidatedIsRefusedInTheJobThatPosts() {
    let outcome = recheck(FakeField("This is ready.", selected: isRange))
    #expect(outcome.result == .mismatch(.paragraphChanged))
    #expect(!outcome.ran.contains("clipboard"))
    #expect(!outcome.ran.contains("post"))
}

@Test func aChangedParagraphIsReportedBeforeAMovedSelection() {
    let outcome = recheck(FakeField("This is ready.", selected: TextRange(location: 0, length: 0)))
    #expect(outcome.result == .mismatch(.paragraphChanged))
}

@Test func eachOtherRecheckMismatchStopsBeforeThePost() {
    let field = FakeField("They is ready.", selected: isRange)
    #expect(recheck(field, frontmost: false).result == .mismatch(.notFrontmost))
    #expect(recheck(field, focused: false).result == .mismatch(.otherField))
    let moved = recheck(FakeField("They is ready.", selected: TextRange(location: 0, length: 0)))
    #expect(moved.result == .mismatch(.selectionMoved))
    let copied = recheck(field, held: false)
    #expect(copied.result == .mismatch(.clipboardChanged))
    #expect(copied.ran == ["frontmost", "focused", "clipboard"])
    #expect(!moved.ran.contains("post"))
}

@Test func aParagraphIsUnchangedOnlyWhenItsUTF16UnitsAreTheSame() {
    let angstrom = "\u{212B}"
    let letterA = "\u{C5}"
    #expect(angstrom == letterA)
    let expected = ExpectedText(range: TextRange(location: 0, length: 1), text: angstrom)
    let same = FakeField(angstrom)
    let canonicallyEqual = FakeField(letterA)
    #expect(TextAccessRules.paragraphUnchanged(expected, read: same.string(for:), length: same.length))
    #expect(!TextAccessRules.paragraphUnchanged(expected, read: canonicallyEqual.string(for:), length: canonicallyEqual.length))
}

@Test func aReadOnlyOrUnknownAppIsUnsupported() {
    for app in ["ch.protonmail.desktop", "com.example.editor"] {
        #expect(decide("Hello\nThey is ready\nBye", in: app) == .refuse(.unsupported), "\(app)")
    }
}

@Test func aRangeOutsideTheExpectedParagraphFails() {
    #expect(decide("Hello\nThey is ready\nBye", range: TextRange(location: 16, length: 5)) == .refuse(.failed))
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

/// The capture the caret at `caret` gives in `text`, and whether writing to it would pass the replace checks.
private func captureAt(_ caret: Int, in text: String) -> (capture: SelectionCapture?, writes: Bool) {
    let field = FakeField(text, selected: TextRange(location: caret, length: 0))
    let capture = TextAccessRules.capture(of: notes, reader: field)
    guard let capture else { return (nil, false) }
    let step = TextAccessRules.replaceStep(
        capture.selection, expected: capture.context, isFocusedField: true, read: field.string(for:), length: field.length,
        access: CapabilityTable.access(for: "com.apple.Notes")
    )
    return (capture, step == .write(.accessibility))
}

@Test func aCaretOnABlankLineBelowAParagraphCapturesThatParagraph() {
    let (capture, writes) = captureAt("👍🏽 One.\n".utf16.count, in: "👍🏽 One.\n\nTwo.")
    let paragraph = TextRange(location: 0, length: "👍🏽 One.".utf16.count)
    #expect(capture?.selection == paragraph)
    #expect(capture?.selectedText == "👍🏽 One.")
    #expect(capture?.context == ExpectedText(range: paragraph, text: "👍🏽 One."))
    #expect(writes)
}

@Test func aCaretInAWhitespaceOnlyLineCapturesTheParagraphAbove() {
    let (capture, writes) = captureAt(7, in: "One.\n  \t\nTwo.")
    #expect(capture?.selection == TextRange(location: 0, length: 4))
    #expect(capture?.selectedText == "One.")
    #expect(writes)
}

@Test func aCaretOnABlankLineBeforeAnyTextCapturesTheFirstParagraphBelow() {
    let (capture, writes) = captureAt(1, in: "\n\n👍🏽 One.\nTwo.")
    let paragraph = TextRange(location: 2, length: "👍🏽 One.".utf16.count)
    #expect(capture?.selection == paragraph)
    #expect(capture?.selectedText == "👍🏽 One.")
    #expect(capture?.context == ExpectedText(range: paragraph, text: "👍🏽 One."))
    #expect(writes)
}

@Test func aCaretInAFieldWithoutAnyParagraphCapturesTheEmptySelection() {
    let capture = captureAt(3, in: "  \n\n").capture
    #expect(capture?.selection == TextRange(location: 3, length: 0))
    #expect(capture?.selectedText == "")
}

/// A whitespace-only line is no paragraph of its own, so it is never captured as one.
@Test func aCaretInAWhitespaceOnlyLineOfAFieldWithoutAnyParagraphCapturesTheEmptySelection() {
    let capture = captureAt(1, in: "  \n\n").capture
    #expect(capture?.selection == TextRange(location: 1, length: 0))
    #expect(capture?.selectedText == "")
    #expect(capture?.context == ExpectedText(range: TextRange(location: 1, length: 0), text: ""))
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

@Test func onlyTheTwoSelectionsAWriteProducesCountAsWhatItLeft() {
    func left(_ observed: TextRange?, length: Int = 7) -> TextRange? {
        TextAccessRules.selectionLeft(byWriting: length, over: replaced, observed: observed)
    }
    let caretAfter = TextRange(location: 17, length: 0)
    let replacementSelected = TextRange(location: 10, length: 7)
    #expect(left(caretAfter) == caretAfter)
    #expect(left(replacementSelected) == replacementSelected)
    #expect(left(nil) == nil)
    #expect(left(TextRange(location: 18, length: 0)) == nil)
    #expect(left(TextRange(location: 10, length: 0)) == nil)
    #expect(left(TextRange(location: 3, length: 0)) == nil)
    #expect(left(TextRange(location: 10, length: 4)) == nil)
    #expect(left(TextRange(location: 11, length: 7)) == nil)
    #expect(left(TextRange(location: 17, length: 1)) == nil)
}

@Test func theSelectionsAWriteLeavesAreMeasuredInUTF16Units() {
    let emoji = "\u{1F600}"
    #expect(emoji.utf16.count == 2)
    let caretAfter = TextRange(location: 12, length: 0)
    #expect(TextAccessRules.selectionLeft(byWriting: emoji.utf16.count, over: replaced, observed: caretAfter) == caretAfter)
    #expect(TextAccessRules.selectionLeft(byWriting: emoji.utf16.count, over: replaced, observed: TextRange(location: 11, length: 0)) == nil)
}

@Test func aWriteWithNothingToInsertLeavesTheCaretAtTheStartOfTheRange() {
    let start = TextRange(location: 10, length: 0)
    #expect(TextAccessRules.selectionLeft(byWriting: 0, over: replaced, observed: start) == start)
    #expect(TextAccessRules.selectionLeft(byWriting: 0, over: replaced, observed: TextRange(location: 14, length: 0)) == nil)
}

@Test func theSelectionAPasteLeavesIsOneOfTheSelectionsAnAccessibilityWriteLeaves() {
    let afterPaste = TextRange(location: 17, length: 0)
    #expect(TextAccessRules.selectionLeft(byWriting: 7, over: replaced, observed: afterPaste) == afterPaste)
    #expect(
        TextAccessRules.pasteCaret(
            user: TextRange(location: 30, length: 0), replaced: replaced, replacementLength: 7, end: .confirmed,
            current: afterPaste, stillFocused: true
        ) == TextRange(location: 33, length: 0)
    )
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

@Test func anAccessibilityWriteLeavesACaretTheUserMovedBeforeTheSelectionWasVerified() {
    let moved = TextRange(location: 12, length: 0)
    let field = FakeField("They is ready. More text", selected: TextRange(location: 20, length: 0))
    field.userMovesSelectionTo = moved
    let expected = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
    let outcome = AccessibilityWrite.perform(
        TextRange(location: 5, length: 2), with: "are", expected: expected, reader: field,
        setSelectedText: field.setSelectedText, isFocused: { true }
    )
    #expect(outcome == .failed)
    #expect(field.text == "They is ready. More text")
    #expect(field.selected == moved)
}

@Test func anAccessibilityWriteLeavesACaretTheUserMovedBeforeTheWriteFailed() {
    let moved = TextRange(location: 12, length: 0)
    let field = FakeField("They is ready. More text", selected: TextRange(location: 20, length: 0))
    let expected = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
    let outcome = AccessibilityWrite.perform(
        TextRange(location: 5, length: 2), with: "are", expected: expected, reader: field,
        setSelectedText: { _ in
            field.selected = moved
            return false
        },
        isFocused: { true }
    )
    #expect(outcome == .failed)
    #expect(field.selected == moved)
}

@Test func anAccessibilityWriteLeavesACaretTheUserMovedAfterTheWrite() {
    let moved = TextRange(location: 12, length: 0)
    let field = FakeField("They is ready. More text", selected: TextRange(location: 20, length: 0))
    let expected = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
    let outcome = AccessibilityWrite.perform(
        TextRange(location: 5, length: 2), with: "are", expected: expected, reader: field,
        setSelectedText: { text in
            let wrote = field.setSelectedText(text)
            field.selected = moved
            return wrote
        },
        isFocused: { true }
    )
    #expect(outcome == .replaced)
    #expect(field.text == "They are ready. More text")
    #expect(field.selected == moved)
}

@Test func anAccessibilityWriteTheFieldDoesNotShowLeavesACaretTheUserMoved() {
    let moved = TextRange(location: 12, length: 0)
    let field = FakeField("They is ready. More text", selected: TextRange(location: 20, length: 0))
    field.appliesWrites = false
    let expected = ExpectedText(range: TextRange(location: 0, length: 14), text: "They is ready.")
    let outcome = AccessibilityWrite.perform(
        TextRange(location: 5, length: 2), with: "are", expected: expected, reader: field,
        setSelectedText: { text in
            let wrote = field.setSelectedText(text)
            field.selected = moved
            return wrote
        },
        isFocused: { true }
    )
    #expect(outcome == .failed)
    #expect(field.selected == moved)
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
    var registry = FieldRegistry<Node, FakeField>(isSame: ==) { _ in true }
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

@Test func aDisabledAppIsNoFieldAndAWebAreaResolvedToItselfIsOne() {
    #expect(!TextAccessRules.isFieldCandidate(role: "AXTextArea", subrole: nil, appEnabled: false))
    #expect(TextAccessRules.isFieldCandidate(role: "AXWebArea", subrole: nil, appEnabled: true))
    #expect(TextAccessRules.isFieldCandidate(role: "AXTextArea", subrole: nil, appEnabled: true))
}

@Test func theBoundsProbeUsesOneUnitAtTheCaret() {
    #expect(TextAccessRules.boundsProbeRange(selection: TextRange(location: 3, length: 0), totalLength: 10) == TextRange(location: 3, length: 1))
    #expect(TextAccessRules.boundsProbeRange(selection: TextRange(location: 10, length: 0), totalLength: 10) == TextRange(location: 9, length: 1))
    #expect(TextAccessRules.boundsProbeRange(selection: TextRange(location: 0, length: 0), totalLength: 0) == nil)
}

// MARK: Registry

@Test func theSameElementKeepsItsFieldAndItsSource() {
    var registry = FieldRegistry<Node, FakeField>(isSame: ==) { _ in true }
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
    var registry = FieldRegistry<Node, FakeField>(isSame: ==) { _ in true }
    let ids = (0 ..< 21).compactMap { registry.focus(Node(id: $0), app: "com.apple.Notes", isCandidate: true) { FakeField("") } }
    #expect(ids.count == 21)
    #expect(registry.entry(ids[0]) == nil)
    #expect(registry.entry(ids[1])?.element == Node(id: 1))
    #expect(registry.newest(app: "com.apple.Notes")?.id == ids[20])
}

@Test func aFieldWithoutASourceIsNotRegistered() {
    var registry = FieldRegistry<Node, FakeField>(isSame: ==) { _ in true }
    #expect(registry.focus(Node(id: 1), app: "com.apple.mail", isCandidate: true) { nil } == nil)
    #expect(registry.newest(app: "com.apple.mail") == nil)
}

/// An element whose role and subrole the test can change after it was registered.
private final class Changing: @unchecked Sendable { // reason: role and subrole are only touched under the lock
    private let lock = NSLock()
    private var current: (role: String?, subrole: String?)

    init(role: String?, subrole: String? = nil) {
        current = (role, subrole)
    }

    var role: String? { lock.withLock { current.role } }
    var subrole: String? { lock.withLock { current.subrole } }

    func become(role: String?, subrole: String? = nil) {
        lock.withLock { current = (role, subrole) }
    }
}

/// The registry as the observer keeps it, touched only inside `AXQueue` jobs once the test registered its field.
private final class Registered: @unchecked Sendable { // reason: only touched inside AXQueue jobs, which run one at a time
    var registry = FieldRegistry<Changing, FakeField>(isSame: ===) {
        TextAccessRules.isFieldCandidate(role: $0.role, subrole: $0.subrole, appEnabled: true)
    }
}

@Test(arguments: [("AXSecureTextField", nil), ("AXTextArea", "AXSecureTextField"), (nil, nil)] as [(String?, String?)])
func aFieldThatTurnsSecureOrUnreadableWhileAJobWaitsIsNotRead(_ role: String?, _ subrole: String?) async throws {
    let element = Changing(role: "AXTextArea")
    let source = FakeField("a secret")
    let fields = Registered()
    let id = try #require(fields.registry.focus(element, app: "com.apple.Notes", isCandidate: true) { source })
    let queue = AXQueue()
    let release = DispatchSemaphore(value: 0)
    let started = Recorder<Bool>()
    let blocker = Task {
        await queue.run {
            started.append(true)
            release.wait()
        }
    }
    for _ in 0 ..< 1_000 where started.values.isEmpty {
        try? await Task.sleep(for: .milliseconds(5))
    }
    let job = Task {
        await queue.run { fields.registry.entry(id).flatMap { TextAccessRules.snapshot(of: id, reader: $0.source) } }
    }
    element.become(role: role, subrole: subrole)
    release.signal()
    await blocker.value
    #expect(await job.value == nil)
    #expect(await queue.run { fields.registry.newest(app: "com.apple.Notes") == nil })
    #expect(source.valueReads == 0)
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

@Test func aFocusWaitAsksOnceMoreAtItsDeadline() async {
    let clock = TestClock()
    let waits = FocusWaits(clock: clock)
    let focused = Recorder<Bool>()
    let waiting = Task { await waits.wait(for: notes, timeout: .seconds(1)) { !focused.values.isEmpty } }
    await clock.waitForSleepCalls(1)
    focused.append(true)
    clock.advance(by: .seconds(1))
    #expect(await waiting.value)
}

// MARK: Capture lines

@Test func aSelectedLineWithItsLineBreakTakesTheNextLineIntoItsContext() {
    let field = FakeField("One two.\nThree four.\nFive.", selected: TextRange(location: 0, length: 9))
    let capture = TextAccessRules.capture(of: notes, reader: field)
    #expect(capture?.selection == TextRange(location: 0, length: 9))
    #expect(capture?.context == ExpectedText(range: TextRange(location: 0, length: 20), text: "One two.\nThree four."))
    let check = FakeField("One two.\nThree four.\nFive.")
    #expect(capture.map { TextAccessRules.paragraphUnchanged($0.context, read: check.string(for:), length: check.length) } == true)
}

@Test func aSelectionOfOnlyALineBreakTakesBothLinesItJoins() {
    let field = FakeField("One.\nTwo.", selected: TextRange(location: 4, length: 1))
    let capture = TextAccessRules.capture(of: notes, reader: field)
    #expect(capture?.selectedText == "\n")
    #expect(capture?.context == ExpectedText(range: TextRange(location: 0, length: 9), text: "One.\nTwo."))
}

// MARK: Unknown roles

@Test func anElementWhoseRoleCantBeReadIsNoFieldAndIsNeverRead() {
    #expect(!TextAccessRules.isFieldCandidate(role: nil, subrole: nil, appEnabled: true))
    #expect(!TextAccessRules.isFieldCandidate(role: nil, subrole: "AXSearchField", appEnabled: true))
    var registry = FieldRegistry<Node, FakeField>(isSame: ==) { _ in true }
    let reads = Recorder<Int>()
    let candidate = TextAccessRules.isFieldCandidate(role: nil, subrole: nil, appEnabled: true)
    let id = registry.focus(Node(id: 1), app: "com.apple.Notes", isCandidate: candidate) {
        reads.append(1)
        return FakeField("unknown")
    }
    #expect(FieldEvent.focused(id) == .focused(nil))
    #expect(reads.values.isEmpty)
}

// MARK: The focus driver

/// The Accessibility side, faked: a focused element per app, and every step the driver asks for.
private final class FakePort: FocusPort, @unchecked Sendable { // reason: each test touches it from one task at a time
    var focus: [pid_t: FocusMachine.QueryResult] = [:]
    private(set) var events: [FieldEvent] = []
    private(set) var observed: [pid_t?] = []
    private(set) var ensured: [pid_t] = []
    private(set) var queries: [pid_t] = []

    func observe(pid: pid_t?, app: String?) { observed.append(pid) }
    func ensureObserved(pid: pid_t, app: String) { ensured.append(pid) }

    func queryFocus(pid: pid_t, app: String) -> FocusMachine.QueryResult {
        queries.append(pid)
        return focus[pid] ?? .missing
    }

    func watch(_ field: FieldID?) {}
    func emit(_ event: FieldEvent) { events.append(event) }
}

private let skaldPID: pid_t = 7
private let obsidianPID: pid_t = 42
private let notesPID: pid_t = 43
private let obsidianField = FieldID(app: "md.obsidian", token: "1")
private let notesField = FieldID(app: "com.apple.Notes", token: "2")

/// A driver whose retries report each finished attempt on `ticks`.
private func makeDriver(_ clock: TestClock, port: FakePort) -> (FocusDriver, AsyncStream<FocusAttempt>) {
    let (ticks, tick) = AsyncStream.makeStream(of: FocusAttempt.self)
    let driver = FocusDriver(ownPID: skaldPID, clock: clock) { body in
        let attempt = body()
        tick.yield(attempt)
        return attempt
    }
    driver.port = port
    return (driver, ticks)
}

@Test func theObserverEmitsFocusedWhenARetryFindsTheElement() async {
    let clock = TestClock()
    let port = FakePort()
    let (driver, ticks) = makeDriver(clock, port: port)
    var attempts = ticks.makeAsyncIterator()
    driver.activated(pid: obsidianPID, app: "md.obsidian", enabled: true)
    #expect(port.events == [.focused(nil)])
    await clock.waitForSleepCalls(1)
    clock.advance(by: .seconds(1))
    #expect(await attempts.next() == .missing)
    port.focus[obsidianPID] = .element(obsidianField)
    await clock.waitForSleepCalls(2)
    clock.advance(by: .seconds(2))
    #expect(await attempts.next() == .found)
    #expect(port.events == [.focused(nil), .focused(obsidianField)])
    #expect(port.ensured == [obsidianPID])
    #expect(driver.current == obsidianField)
}

@Test func aFocusChangeCancelsThePendingRetries() async {
    let clock = TestClock()
    let port = FakePort()
    let (driver, _) = makeDriver(clock, port: port)
    driver.activated(pid: obsidianPID, app: "md.obsidian", enabled: true)
    await clock.waitForSleepCalls(1)
    driver.focusChanged(pid: obsidianPID)
    clock.advance(by: .seconds(20))
    #expect(clock.wokenDeadlines.isEmpty)
    #expect(port.queries == [obsidianPID, obsidianPID])
}

@Test func aFrontmostChangeCancelsThePendingRetries() async {
    let clock = TestClock()
    let port = FakePort()
    let (driver, _) = makeDriver(clock, port: port)
    port.focus[notesPID] = .element(notesField)
    driver.activated(pid: obsidianPID, app: "md.obsidian", enabled: true)
    await clock.waitForSleepCalls(1)
    driver.activated(pid: notesPID, app: "com.apple.Notes", enabled: true)
    clock.advance(by: .seconds(20))
    #expect(clock.wokenDeadlines.isEmpty)
    #expect(port.events == [.focused(nil), .focused(notesField)])
}

@Test func theSameFieldFocusedAgainIsNoEvent() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    port.focus[notesPID] = .element(notesField)
    driver.activated(pid: notesPID, app: "com.apple.Notes", enabled: true)
    driver.focusChanged(pid: notesPID)
    #expect(port.events == [.focused(notesField)])
    port.focus[notesPID] = .element(nil)
    driver.focusChanged(pid: notesPID)
    driver.focusChanged(pid: notesPID)
    #expect(port.events == [.focused(notesField), .focused(nil), .focused(nil)])
}

@Test func skaldsOwnAppIsNoFieldAndIsNeverAsked() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    port.focus[skaldPID] = .element(notesField)
    driver.activated(pid: skaldPID, app: "com.michaelrigart.skald", enabled: true)
    #expect(port.events == [.focused(nil)])
    #expect(port.queries.isEmpty)
    #expect(port.observed == [nil])
}

@Test func aDisabledAppIsNoFieldAndIsNeverAsked() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    port.focus[notesPID] = .element(notesField)
    driver.activated(pid: notesPID, app: "com.apple.Notes", enabled: false)
    #expect(port.events == [.focused(nil)])
    #expect(port.queries.isEmpty)
}

@Test func changesAreTheCurrentFieldsAndOnlyTheFrontmostAppsCount() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    port.focus[notesPID] = .element(notesField)
    driver.activated(pid: notesPID, app: "com.apple.Notes", enabled: true)
    driver.fieldChanged(pid: notesPID, value: true)
    driver.fieldChanged(pid: notesPID, value: false)
    driver.fieldChanged(pid: obsidianPID, value: true)
    #expect(port.events == [.focused(notesField), .edited(notesField), .caretMoved(notesField)])
}

@Test func aFocusChangeInAnAppThatIsNotFrontmostIsIgnored() {
    var idle = FocusMachine(ownPID: skaldPID)
    #expect(idle.focusChanged(pid: obsidianPID).isEmpty)
    var machine = FocusMachine(ownPID: skaldPID)
    _ = machine.activated(pid: notesPID, app: "com.apple.Notes", enabled: true)
    #expect(machine.focusChanged(pid: obsidianPID).isEmpty)
    #expect(!machine.retryTick(generation: machine.generation - 1, pid: notesPID))
    #expect(machine.retryTick(generation: machine.generation, pid: notesPID))
}

// MARK: A late grant and the app switches

@Test func aGrantAfterLaunchObservesTheFrontmostAppAgainAndFindsItsField() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    driver.activated(pid: obsidianPID, app: "md.obsidian", enabled: true)
    #expect(port.events == [.focused(nil)])
    port.focus[obsidianPID] = .element(obsidianField)
    driver.reactivated(isEnabled: { _ in true })
    #expect(port.observed == [obsidianPID, obsidianPID])
    #expect(port.events == [.focused(nil), .focused(obsidianField)])
    #expect(driver.current == obsidianField)
}

@Test func aGrantBeforeAnyActivationDoesNothing() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    driver.reactivated(isEnabled: { _ in true })
    #expect(port.observed.isEmpty)
    #expect(port.events.isEmpty)
}

@Test func turningOffTheFocusedAppEmitsNoFieldAtOnceAndStopsObservingIt() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    port.focus[notesPID] = .element(notesField)
    driver.activated(pid: notesPID, app: "com.apple.Notes", enabled: true)
    driver.switchesChanged(isEnabled: { $0 != "com.apple.Notes" })
    #expect(port.events == [.focused(notesField), .focused(nil)])
    #expect(port.observed == [notesPID, nil])
    #expect(port.queries == [notesPID])
    #expect(driver.current == nil)
}

@Test func turningOnTheFrontmostAppObservesItAndFindsItsField() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    port.focus[notesPID] = .element(notesField)
    driver.activated(pid: notesPID, app: "com.apple.Notes", enabled: false)
    driver.switchesChanged(isEnabled: { _ in true })
    #expect(port.events == [.focused(nil), .focused(notesField)])
    #expect(port.observed == [nil, notesPID])
}

@Test func switchesThatLeaveTheFrontmostAppAloneChangeNothing() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    port.focus[notesPID] = .element(notesField)
    driver.activated(pid: notesPID, app: "com.apple.Notes", enabled: true)
    driver.switchesChanged(isEnabled: { _ in true })
    #expect(port.events == [.focused(notesField)])
    #expect(port.observed == [notesPID])
    #expect(port.queries == [notesPID])
}

@Test func aVisibleRangeInsideTheFieldIsKept() {
    #expect(TextAccessRules.visibleRange(TextRange(location: 120, length: 800), totalLength: 5_000) == TextRange(location: 120, length: 800))
    #expect(TextAccessRules.visibleRange(TextRange(location: 0, length: 5_000), totalLength: 5_000) == TextRange(location: 0, length: 5_000))
}

/// Without a range the overlay asks for every issue's bounds, so a range that can't be right must come out nil.
@Test func anEmptyVisibleRangeOrOnePastTheFieldsEndGivesNone() {
    #expect(TextAccessRules.visibleRange(TextRange(location: 40, length: 0), totalLength: 5_000) == nil)
    #expect(TextAccessRules.visibleRange(TextRange(location: 4_900, length: 101), totalLength: 5_000) == nil)
    #expect(TextAccessRules.visibleRange(TextRange(location: 5_001, length: 1), totalLength: 5_000) == nil)
    #expect(TextAccessRules.visibleRange(TextRange(location: -1, length: 10), totalLength: 5_000) == nil)
    #expect(TextAccessRules.visibleRange(nil, totalLength: 5_000) == nil)
    #expect(TextAccessRules.visibleRange(TextRange(location: 0, length: 10), totalLength: nil) == nil)
}

@Test func switchesNeverObserveSkaldItself() {
    let port = FakePort()
    let (driver, _) = makeDriver(TestClock(), port: port)
    driver.activated(pid: skaldPID, app: "com.michaelrigart.skald", enabled: false)
    driver.switchesChanged(isEnabled: { _ in true })
    #expect(port.observed == [nil])
    #expect(port.events == [.focused(nil)])
}
