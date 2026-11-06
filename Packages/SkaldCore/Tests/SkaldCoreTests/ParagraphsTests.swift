import Foundation
import Testing
@testable import SkaldCore
import struct SkaldCore.TextRange

private let field = FieldID(app: "app", token: "a")

private func substring(_ text: String, _ range: TextRange) -> String {
    (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
}

private func longParagraph() -> String {
    (0..<10).map { _ in String(repeating: "x", count: 298) + ". " }.joined()
}

@Test func caretInSecondLineReturnsThatLineWithItsFieldRange() {
    let text = "first line\nsecond line\nthird line"
    let p = Paragraphs.around(caret: 14, in: text, offset: 0)
    #expect(p == Paragraph(range: TextRange(location: 11, length: 11), text: "second line"))
}

@Test func caretAtTheEndOfALineBelongsToIt() {
    let text = "first line\nsecond line"
    #expect(Paragraphs.around(caret: 10, in: text, offset: 0)?.text == "first line")
}

@Test func rangesAreShiftedByTheWindowOffset() {
    let all = Paragraphs.all(in: "one\ntwo", offset: 100)
    #expect(all.map(\.range) == [TextRange(location: 100, length: 3), TextRange(location: 104, length: 3)])
}

@Test func crlfAndParagraphSeparatorsBreakParagraphs() {
    let text = "one\r\ntwo\u{2029}three\u{2028}four\rfive\nsix"
    let all = Paragraphs.all(in: text, offset: 0)
    #expect(all.map(\.text) == ["one", "two", "three", "four", "five", "six"])
    #expect(all.allSatisfy { substring(text, $0.range) == $0.text })
}

@Test func emojiParagraphKeepsUTF16Ranges() {
    let line = "👍🏽 Ik heb dit gedownloaded"
    let text = "intro\n" + line + "\nlast"
    let all = Paragraphs.all(in: text, offset: 0)
    #expect(all[1].range == TextRange(location: 6, length: line.utf16.count))
    #expect(all[1].range.length != line.count)
    #expect(substring(text, all[1].range) == line)
    #expect(all[2].range.location == all[1].range.end + 1)
}

@Test func shortParagraphIsOneChunk() {
    let p = Paragraph(range: TextRange(location: 5, length: 3), text: "abc")
    #expect(Paragraphs.chunks(p) == [p])
}

@Test func longParagraphChunksAtSentenceEnds() {
    let text = longParagraph()
    #expect(text.utf16.count == 3000)
    let p = Paragraph(range: TextRange(location: 50, length: 3000), text: text)
    let chunks = Paragraphs.chunks(p)
    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { $0.range.length <= 1200 && $0.text.utf16.count == $0.range.length })
    #expect(chunks.map(\.text).joined() == text)
    #expect(chunks.map(\.range.location) == [50, 1250, 2450])
}

@Test func aSingleSentenceOverTheLimitIsItsOwnChunk() {
    let big = String(repeating: "y", count: 1500) + ". "
    let text = "Short one. " + big + "Short two."
    let p = Paragraph(range: TextRange(location: 0, length: text.utf16.count), text: text)
    let chunks = Paragraphs.chunks(p)
    #expect(chunks.map(\.text) == ["Short one. ", big, "Short two."])
}

@Test func keyedCountsIdenticalParagraphsAsOccurrences() {
    let text = "They is ready\nok\nThey is ready"
    let snapshot = FieldSnapshot(field: field, text: text, offset: 0, selection: TextRange(location: 0, length: 0), totalLength: text.utf16.count)
    let keyed = ParagraphKeys.keyed(snapshot)
    #expect(keyed.map(\.0.position) == [.occurrence(0), .occurrence(0), .occurrence(1)])
    #expect(keyed.map(\.0.chunk) == [0, 0, 0])
    #expect(keyed[0].0 != keyed[2].0)
}

@Test func keyedInAWindowUsesLocations() {
    let text = "They is ready\nok\nThey is ready"
    let snapshot = FieldSnapshot(field: field, text: text, offset: 0, selection: TextRange(location: 0, length: 0), totalLength: 60_000)
    let keyed = ParagraphKeys.keyed(snapshot)
    #expect(keyed.map(\.0.position) == [.location(0), .location(14), .location(17)])
}

@Test func chunkKeysCoverEveryChunkOfTheCaretParagraph() {
    let long = longParagraph()
    let text = "short\n" + long
    let snapshot = FieldSnapshot(field: field, text: text, offset: 0, selection: TextRange(location: 100, length: 0), totalLength: text.utf16.count)
    let keys = ParagraphKeys.chunkKeys(snapshot, caret: 100)
    #expect(keys.map(\.0.chunk) == [0, 1, 2])
    #expect(keys.allSatisfy { $0.0.text == long && $0.parent.text == long })
    #expect(keys.map(\.chunk.text).joined() == long)
    #expect(keys[1].chunk.range.location == 6 + 1200)
}

@Test func paragraphsBreakAtExactlyFourUnits() {
    let breaks = (0...UInt16.max).filter(Paragraphs.isLineBreak)
    #expect(breaks == [0x0A, 0x0D, 0x2028, 0x2029])
    #expect(PanelText.paragraphs("a\u{2028}b\rc").map(\.text) == ["a", "b", "c"])
}
