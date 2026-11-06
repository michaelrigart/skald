import ApplicationServices
import Foundation
import Testing
@testable import SkaldPlatform27

private let markerLength = ProbeMarker.length

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

@Test func eachPendingMarkerMapsToTheOkMarkerOfItsOwnPair() {
    #expect(ProbeMarker.pair(pending: "~skald-probe~")?.replacement == "~skald-ok~")
    #expect(ProbeMarker.pair(pending: "[skald-probe]")?.replacement == "[skald-ok]")
    #expect(ProbeMarker.match(in: "Hi [skald-probe]", caret: nil)?.pair == .bracket)
    #expect(ProbeMarker.match(in: "Hi ~skald-probe~", caret: nil)?.pair == .tilde)
    #expect(ProbeMarker.match(in: "Hi [skald-probe]\n\nSignature", caret: caret(16))?.pair == .bracket)
}

@Test func aMixedPairIsNotAMarker() {
    #expect(ProbeMarker.pair(pending: "~skald-probe]") == nil)
    #expect(ProbeMarker.pair(pending: "[skald-probe~") == nil)
    #expect(found("Hi ~skald-probe]", nil) == nil)
    #expect(found("Hi [skald-probe~", nil) == nil)
    #expect(!ProbeMarker.containsPending("Hi [skald-probe~ and ~skald-probe]"))
    #expect(ProbeMarker.containsPending("Hi [skald-probe] there"))
}

@Test func bothPairsHaveTheSameLengths() {
    for pair in ProbeMarker.pairs {
        #expect((pair.pending as NSString).length == 13)
        #expect((pair.replacement as NSString).length == 10)
    }
    #expect(ProbeMarker.length == 13)
}

@Test func theBracketPairIsWrittenAsItsOwnOkMarker() {
    var start = WriteStart(original: "😀 [skald-probe] tail", before: nil, beforeLocation: 0, beforeLength: 3)
    start.pair = .bracket
    #expect(start.expectedAfterWrite == "😀 [skald-ok] tail")
    #expect(ProbeMarker.tailSummary(of: "Hi [skald-probe]\nSecret") == "7 units after it, starts with a newline true")
    #expect(ProbeMarker.caretSummary(of: "Hi [skald-probe] tail", caret: caret(0), characterCount: nil)
        == "caret 0,0, last marker ends at 16, value 21 units, characters none")
}
