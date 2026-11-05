import ApplicationServices
import Foundation
import Testing
@testable import SkaldPlatform27

private let markerLength = (ProbeMarker.pending as NSString).length

private func caret(_ location: Int, _ length: Int = 0) -> CFRange {
    CFRange(location: location, length: length)
}

private func found(_ value: String, _ caret: CFRange?) -> (location: Int, length: Int)? {
    ProbeMarker.range(in: value, caret: caret).map { ($0.location, $0.length) }
}

@Test func aMarkerAtTheEndOfTheValueCounts() {
    let value = "Hello ~skald-probe~"
    #expect(found(value, nil)?.location == 6)
    #expect(found(value, nil)?.length == markerLength)
    #expect(found(value, caret(0))?.location == 6)
    #expect(found(value, caret(6, markerLength))?.location == 6)
}

@Test func aMarkerBeforeTrailingTextCountsWhenTheCaretEndsIt() {
    let value = "Hi ~skald-probe~\n\nSignature"
    #expect(found(value, caret(3 + markerLength))?.location == 3)
    #expect(found(value, caret(3 + markerLength))?.length == markerLength)
}

@Test func aMarkerBeforeTrailingTextIsIgnoredWithTheCaretElsewhere() {
    let value = "Hi ~skald-probe~\n\nSignature"
    #expect(found(value, caret(0)) == nil)
    #expect(found(value, caret(3 + markerLength + 1)) == nil)
    #expect(found(value, caret(value.utf16.count)) == nil)
    #expect(found(value, nil) == nil)
}

@Test func aSelectionThatIsNotCollapsedOnlyCountsForASuffixMarker() {
    let value = "Hi ~skald-probe~\n\nSignature"
    #expect(found(value, caret(3, markerLength)) == nil)
    #expect(found(value, caret(3 + markerLength - 1, 1)) == nil)
}

@Test func aCaretCannotEndAMarkerThatWouldStartBeforeTheValue() {
    #expect(found("short", caret(3)) == nil)
    #expect(found("~skald-probe~ tail", caret(500)) == nil)
}

@Test func theMarkerIsLocatedInUTF16UnitsAfterAnEmoji() {
    let value = "😀 ~skald-probe~ tail"
    let end = 3 + markerLength
    #expect(found(value, caret(end))?.location == 3)
    #expect(found(value, caret(value.count - 5)) == nil)
}

@Test func theExpectedValueKeepsTheTextAfterTheMarker() {
    let original = "😀 ~skald-probe~ tail"
    let start = WriteStart(original: original, before: nil, beforeLocation: 0, beforeLength: 3)
    #expect(start.expectedAfterWrite == "😀 ~skald-ok~ tail")
    let suffix = WriteStart(original: "Hello ~skald-probe~", before: nil, beforeLocation: 0, beforeLength: 6)
    #expect(suffix.expectedAfterWrite == "Hello ~skald-ok~")
}

@Test func theTailSummaryHasOnlyACountAndANewlineFlag() {
    #expect(ProbeMarker.tailSummary(of: "Hi ~skald-probe~\nSecret signature") == "17 units after it, starts with a newline true")
    #expect(ProbeMarker.tailSummary(of: "Hi ~skald-probe~\r\nSecret") == "8 units after it, starts with a newline true")
    #expect(ProbeMarker.tailSummary(of: "Hi ~skald-probe~ 😀") == "3 units after it, starts with a newline false")
    #expect(ProbeMarker.tailSummary(of: "no marker here") == nil)
    let summary = ProbeMarker.tailSummary(of: "Hi ~skald-probe~\nSecret signature") ?? ""
    #expect(!summary.contains("Secret") && !summary.contains("U+"))
}

@Test func theCaretSummaryHasOnlyNumbersForAMarkerTheCaretDoesNotEnd() {
    let value = "😀 ~skald-probe~ Secret tail"
    let summary = ProbeMarker.caretSummary(of: value, caret: caret(0, 4), characterCount: 25)
    #expect(summary == "caret 0,4, last marker ends at 16, value 28 units, characters 25")
    #expect(ProbeMarker.caretSummary(of: value, caret: nil, characterCount: nil)
        == "caret none, last marker ends at 16, value 28 units, characters none")
    #expect(!(summary ?? "").contains("Secret"))
}

@Test func theCaretSummaryIsSilentWhenTheMarkerCountsOrIsAbsent() {
    #expect(ProbeMarker.caretSummary(of: "Hi ~skald-probe~", caret: nil, characterCount: 16) == nil)
    #expect(ProbeMarker.caretSummary(of: "Hi ~skald-probe~ tail", caret: caret(16), characterCount: nil) == nil)
    #expect(ProbeMarker.caretSummary(of: "nothing here", caret: caret(3), characterCount: nil) == nil)
}
