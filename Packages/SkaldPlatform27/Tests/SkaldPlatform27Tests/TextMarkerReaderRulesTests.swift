import CoreGraphics
import Foundation
import SkaldCore
import Testing
@testable import SkaldPlatform27
import struct SkaldCore.TextRange

/// A ranges field held in memory, read through Task 13's read decision.
private final class RangesField: FieldReader, @unchecked Sendable { // reason: each test touches it from one task at a time
    let text: String
    let selected: TextRange?
    let rangedReads: Bool

    init(_ text: String, selected: TextRange? = TextRange(location: 0, length: 0), rangedReads: Bool) {
        self.text = text
        self.selected = selected
        self.rangedReads = rangedReads
    }

    func length() -> Int? { text.utf16.count }
    func selection() -> TextRange? { selected }

    func string(for range: TextRange) -> String? {
        TextAccessRules.read(
            range,
            ranged: { rangedReads && range.end <= text.utf16.count ? substring(range) : nil },
            length: { text.utf16.count },
            value: { text }
        )
    }

    func bounds(for range: TextRange) -> CGRect? { nil }
    func select(_ range: TextRange) -> Bool { false }

    private func substring(_ range: TextRange) -> String {
        (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
}

/// The source the registry picks for `field`, recording whether the text markers were asked.
private func source(of field: RangesField, markersAnswer: Bool) -> (kind: FieldKind?, askedMarkers: Bool) {
    var asked = false
    let kind = TextAccessRules.source(rangesReadable: TextAccessRules.window(of: field) != nil) {
        asked = true
        return markersAnswer
    }
    return (kind, asked)
}

// MARK: Choosing the source

@Test func aFieldWithAWorkingRangedReadUsesRangesAndNeverAsksTheMarkers() {
    let chosen = source(of: RangesField("They is ready.", rangedReads: true), markersAnswer: true)
    #expect(chosen.kind == .ranges)
    #expect(!chosen.askedMarkers)
}

@Test func withoutRangedReadsAFieldOfAtMost20000UnitsUsesRangesWithItsFullValue() {
    let field = RangesField(String(repeating: "a", count: 20_000), rangedReads: false)
    let chosen = source(of: field, markersAnswer: true)
    #expect(chosen.kind == .ranges)
    #expect(!chosen.askedMarkers)
    #expect(TextAccessRules.snapshot(of: FieldID(app: "com.apple.mail", token: "1"), reader: field)?.text.utf16.count == 20_000)
}

@Test func aFieldNeitherRangedNorShortEnoughUsesTextMarkersWhenTheyAnswer() {
    let long = RangesField(String(repeating: "a", count: 20_001), rangedReads: false)
    #expect(source(of: long, markersAnswer: true).kind == .textMarkers)
    let unselected = RangesField("They is ready.", selected: nil, rangedReads: true)
    #expect(source(of: unselected, markersAnswer: true).kind == .textMarkers)
}

@Test func aFieldNoSourceCanReadHasNoSnapshot() {
    let chosen = source(of: RangesField(String(repeating: "a", count: 20_001), rangedReads: false), markersAnswer: false)
    #expect(chosen.kind == nil)
    #expect(chosen.askedMarkers)
}

// MARK: Text-marker reads

@Test func aTextMarkerFieldIsReadWholeUpTo20000Units() {
    let text = String(repeating: "a", count: 20_000)
    #expect(TextAccessRules.markerText(length: 20_000) { text } == text)
}

@Test func aLongerTextMarkerFieldIsNotReadAtAll() {
    var asked = false
    let text = TextAccessRules.markerText(length: 20_001) {
        asked = true
        return String(repeating: "a", count: 20_001)
    }
    #expect(text == nil)
    #expect(!asked)
}

@Test func aTextMarkerReadWhoseLengthDisagreesOrIsMissingIsNotTrusted() {
    #expect(TextAccessRules.markerText(length: 5) { "abcd" } == nil)
    #expect(TextAccessRules.markerText(length: nil) { "abcd" } == nil)
    #expect(TextAccessRules.markerText(length: 4) { nil } == nil)
}

@Test func aMarkerLengthTheAppDoesNotAnswerIsUnknownAndTheFieldIsNeverReadToMeasureIt() {
    var reads = 0
    func read() -> String? {
        reads += 1
        return "They is ready."
    }
    #expect(TextMarkerField.measuredLength(answered: 14, readsToMeasure: false, read: read) == 14)
    #expect(TextMarkerField.measuredLength(answered: nil, readsToMeasure: false, read: read) == nil)
    #expect(reads == 0)
    #expect(TextMarkerField.measuredLength(answered: nil, readsToMeasure: true, read: read) == 14)
}

@Test func aTextMarkerFieldThatCannotBeReadNamesAFixedKind() {
    #expect(TextAccessRules.markerUnreadKind(length: nil) == "the app gives no marker lengths")
    #expect(TextAccessRules.markerUnreadKind(length: 20_001) == "over the read limit")
    #expect(TextAccessRules.markerUnreadKind(length: 20_000) == nil)
}

// MARK: Selecting by markers

/// Text markers over a text: one marker before each grapheme and one at the end, so a wide grapheme is one step.
private final class Markers: @unchecked Sendable { // reason: each test touches it from one task at a time
    let offsets: [Int]
    private(set) var steps = 0

    init(_ text: String) {
        var offsets = [0]
        for character in text { offsets.append(offsets[offsets.count - 1] + character.utf16.count) }
        self.offsets = offsets
    }

    var end: Int { offsets.count - 1 }

    func offset(_ marker: Int) -> Int? { offsets.indices.contains(marker) ? offsets[marker] : nil }

    func next(_ marker: Int) -> Int? {
        steps += 1
        return marker < end ? marker + 1 : nil
    }

    func previous(_ marker: Int) -> Int? {
        steps += 1
        return marker > 0 ? marker - 1 : nil
    }

    /// The units between two adjacent markers; any wider span is never asked for.
    func length(_ start: Int, _ end: Int) -> Int? {
        end == start + 1 ? offsets[end] - offsets[start] : nil
    }

    func walk(from start: Int, to target: Int) -> Int? {
        TextAccessRules.walk(from: start, at: offsets[start], to: target, next: next, previous: previous, length: length)
    }
}

@Test func aWalkStepsForwardOrBackToTheTargetOffset() {
    let markers = Markers("They is ready.")
    #expect(markers.walk(from: 0, to: 5) == 5)
    #expect(markers.walk(from: markers.end, to: 5) == 5)
    #expect(markers.walk(from: 7, to: 7) == 7)
}

@Test func aWalkOverAWideGraphemeCountsItsUTF16Units() {
    let markers = Markers("👍🏽 Ik heb")
    #expect(markers.offset(1) == 4)
    #expect(markers.walk(from: 0, to: 5) == 2)
    #expect(markers.walk(from: markers.end, to: 4) == 1)
}

@Test func aWalkThatWouldStopInsideAGraphemeIsRefused() {
    let markers = Markers("a👍b")
    #expect(markers.walk(from: 0, to: 2) == nil)
    #expect(markers.walk(from: markers.end, to: 2) == nil)
}

@Test func aWalkOfMoreThan2000UnitsIsRefusedWithoutAStep() {
    let markers = Markers(String(repeating: "a", count: 2_500))
    #expect(markers.walk(from: 0, to: 2_001) == nil)
    #expect(markers.walk(from: 2_500, to: 499) == nil)
    #expect(markers.steps == 0)
    #expect(markers.walk(from: 0, to: 2_000) == 2_000)
}

@Test func aWalkWhoseStepsMakeNoProgressEnds() {
    var steps = 0
    let found = TextAccessRules.walk(from: 0, at: 3, to: 10, next: { marker in
        steps += 1
        return steps < 100 ? marker : nil
    }, previous: { $0 }, length: { _, _ in 0 })
    #expect(found == nil)
    #expect(steps <= 2 * 7)
}

@Test func theStepDecisionReachesStepsAndRefuses() {
    #expect(TextAccessRules.markerStep(origin: 0, current: 5, target: 5, steps: 3) == .reached)
    #expect(TextAccessRules.markerStep(origin: 0, current: 3, target: 5, steps: 3) == .next)
    #expect(TextAccessRules.markerStep(origin: 9, current: 7, target: 5, steps: 2) == .previous)
    #expect(TextAccessRules.markerStep(origin: 0, current: 6, target: 5, steps: 4) == .refused)
    #expect(TextAccessRules.markerStep(origin: 9, current: 4, target: 5, steps: 3) == .refused)
    #expect(TextAccessRules.markerStep(origin: 0, current: nil, target: 5, steps: 0) == .refused)
    #expect(TextAccessRules.markerStep(origin: 0, current: 0, target: 2_001, steps: 0) == .refused)
    #expect(TextAccessRules.markerStep(origin: 0, current: 0, target: -1, steps: 0) == .refused)
}

// MARK: Web areas

private struct Node: Equatable {
    let id: Int
}

private func resolve(
    role: String?, marker: Int?, leaf: Node?, ancestor: Node?, asked: inout [String]
) -> Node? {
    var calls: [String] = []
    let resolved = EditableResolver.resolve(
        role: role, focused: Node(id: 1),
        selectionStart: { () -> Int? in
            calls.append("marker")
            return marker
        },
        element: { (_: Int) -> Node? in
            calls.append("leaf")
            return leaf
        },
        editableAncestor: { (_: Node) -> Node? in
            calls.append("ancestor")
            return ancestor
        }
    )
    asked = calls
    return resolved
}

@Test func aFocusedWebAreaIsTheEditableAncestorOfTheElementAtItsSelectionStart() {
    var asked: [String] = []
    #expect(resolve(role: "AXWebArea", marker: 7, leaf: Node(id: 2), ancestor: Node(id: 3), asked: &asked) == Node(id: 3))
    #expect(asked == ["marker", "leaf", "ancestor"])
}

@Test func mailsComposeWebAreaIsItsOwnEditableAncestor() {
    var asked: [String] = []
    #expect(resolve(role: "AXWebArea", marker: 7, leaf: Node(id: 2), ancestor: Node(id: 1), asked: &asked) == Node(id: 1))
}

@Test func aWebAreaBeingReadIsNoField() {
    var asked: [String] = []
    #expect(resolve(role: "AXWebArea", marker: 7, leaf: Node(id: 2), ancestor: nil, asked: &asked) == nil)
    #expect(resolve(role: "AXWebArea", marker: 7, leaf: nil, ancestor: Node(id: 3), asked: &asked) == nil)
    #expect(asked == ["marker", "leaf"])
}

@Test func aWebAreaWithoutASelectionMarkerIsNoField() {
    var asked: [String] = []
    #expect(resolve(role: "AXWebArea", marker: nil, leaf: Node(id: 2), ancestor: Node(id: 3), asked: &asked) == nil)
    #expect(asked == ["marker"])
}

@Test func anyOtherFocusedElementIsItselfWithoutAMarkerCall() {
    var asked: [String] = []
    #expect(resolve(role: "AXTextArea", marker: 7, leaf: Node(id: 2), ancestor: Node(id: 3), asked: &asked) == Node(id: 1))
    #expect(resolve(role: nil, marker: 7, leaf: Node(id: 2), ancestor: Node(id: 3), asked: &asked) == Node(id: 1))
    #expect(asked.isEmpty)
}
