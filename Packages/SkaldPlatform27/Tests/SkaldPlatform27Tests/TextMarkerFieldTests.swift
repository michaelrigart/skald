import ApplicationServices
import Testing
@testable import SkaldPlatform27

@Test func markersReplaceRangesOnlyWhenTheRangesAreUnusableAndMarkersAnswer() {
    #expect(FieldKind.decide(selectedRangePresent: false, rangedReadFailed: false, markersAnswer: true) == .textMarkers)
    #expect(FieldKind.decide(selectedRangePresent: true, rangedReadFailed: true, markersAnswer: true) == .textMarkers)
    #expect(FieldKind.decide(selectedRangePresent: true, rangedReadFailed: false, markersAnswer: true) == .ranges)
    #expect(FieldKind.decide(selectedRangePresent: false, rangedReadFailed: true, markersAnswer: false) == .ranges)
    #expect(FieldKind.decide(selectedRangePresent: true, rangedReadFailed: true, markersAnswer: false) == .ranges)
}

@Test func theKindIsNamedForTheLog() {
    #expect(FieldKind.ranges.rawValue == "ranges")
    #expect(FieldKind.textMarkers.rawValue == "text markers")
}

@Test func aCaretOffsetMustFitTheText() {
    let fitted = TextMarkerField.checkedCaret(offset: 29, length: 0, textLength: 193)
    #expect(fitted?.location == 29 && fitted?.length == 0)
    let atEnd = TextMarkerField.checkedCaret(offset: 193, length: 0, textLength: 193)
    #expect(atEnd?.location == 193)
    #expect(TextMarkerField.checkedCaret(offset: 194, length: 0, textLength: 193) == nil)
    #expect(TextMarkerField.checkedCaret(offset: 190, length: 4, textLength: 193) == nil)
    #expect(TextMarkerField.checkedCaret(offset: nil, length: 0, textLength: 193) == nil)
    #expect(TextMarkerField.checkedCaret(offset: 5, length: nil, textLength: 193) == nil)
}

@Test func theSelectionIsTheMarkerOnlyWhenItsStringIsExactlyTheMarker() {
    #expect(TextMarkerField.isMarkerSelection(selectedString: ProbeMarker.pending))
    #expect(!TextMarkerField.isMarkerSelection(selectedString: ProbeMarker.pending + " "))
    #expect(!TextMarkerField.isMarkerSelection(selectedString: "~skald-probe"))
    #expect(!TextMarkerField.isMarkerSelection(selectedString: ""))
    #expect(!TextMarkerField.isMarkerSelection(selectedString: nil))
}

@Test func theMarkerIsAnchoredAtTheCaretOrTheEndOfTheText() {
    func range(_ location: Int) -> CFRange { CFRange(location: location, length: ProbeMarker.length) }
    func caret(_ location: Int, _ length: Int = 0) -> CFRange { CFRange(location: location, length: length) }
    #expect(TextMarkerField.anchor(for: range(16), caret: caret(29), textLength: 40) == .selectionStart)
    #expect(TextMarkerField.anchor(for: range(27), caret: caret(0), textLength: 40) == .elementEnd)
    #expect(TextMarkerField.anchor(for: range(27), caret: nil, textLength: 40) == .elementEnd)
    #expect(TextMarkerField.anchor(for: range(16), caret: caret(0), textLength: 40) == nil)
    #expect(TextMarkerField.anchor(for: range(16), caret: caret(16, 13), textLength: 40) == nil)
}
