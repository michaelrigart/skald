import Foundation
import Testing
@testable import SkaldCore
import struct SkaldCore.TextRange

private func apply(_ edit: Edit, to text: String) -> String {
    let ns = text as NSString
    let r = NSRange(location: edit.spliceRange.location, length: edit.spliceRange.length)
    return ns.replacingCharacters(in: r, with: edit.spliceText)
}

private func applyAll(_ edits: [Edit], to text: String) -> String {
    edits.reversed().reduce(text) { apply($1, to: $0) }
}

private func write(_ edit: Edit, to text: String) -> String {
    let r = NSRange(location: edit.writeRange.location, length: edit.writeRange.length)
    return (text as NSString).replacingCharacters(in: r, with: edit.writeText)
}

private func substring(_ text: String, _ range: TextRange) -> String {
    (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
}

@Test func repeatedWordIsOneDeletion() {
    let edits = TextDiff.edits(from: "the the cat", to: "the cat")
    #expect(edits.count == 1)
    #expect(edits[0].replacementTokens.isEmpty)
    #expect(apply(edits[0], to: "the the cat") == "the cat")
}

@Test func wordReplacement() {
    let edits = TextDiff.edits(from: "I've went through", to: "I've gone through")
    #expect(edits.count == 1)
    #expect(edits[0].original == "went")
    #expect(edits[0].replacement == "gone")
    #expect(edits[0].range == TextRange(location: 5, length: 4))
}

@Test func replacementCanSpanSeveralTokens() {
    let edits = TextDiff.edits(from: "ces vraiment", to: "c'est vraiment")
    #expect(edits.count == 1)
    #expect(edits[0].replacementTokens == ["c", "'", "est"])
}

@Test func insertionIsZeroLengthAtNextToken() {
    let edits = TextDiff.edits(from: "a c", to: "a b c")
    #expect(edits.count == 1)
    #expect(edits[0].tokenSpan == 1..<1)
    #expect(edits[0].range == TextRange(location: 2, length: 0))
    #expect(edits[0].original == "")
    #expect(edits[0].replacement == "b")
}

@Test func emojiBeforeFlaggedWordKeepsUTF16Offsets() {
    let original = "👍🏽 Ik heb de versie gedownloaded."
    let edits = TextDiff.edits(from: original, to: "👍🏽 Ik heb de versie gedownload.")
    #expect(edits.count == 1)
    #expect(edits[0].range.location == 22)
    #expect(edits[0].original == "gedownloaded")
    #expect(apply(edits[0], to: original) == "👍🏽 Ik heb de versie gedownload.")
}

@Test func identicalTextHasNoEdits() {
    #expect(TextDiff.edits(from: "same text.", to: "same text.").isEmpty)
}

@Test func applyingEveryEditReproducesTheRevisedText() throws {
    let cases: [EvalCase] = try EvalScorer.loadJSONL(Fixtures.url("testset"))
    let outputs: [EvalOutput] = try EvalScorer.loadJSONL(Fixtures.url("out-apple-v3"))
    let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
    var checked = 0
    for row in outputs {
        guard let out = row.output, let item = byID[row.id] else { continue }
        let edits = TextDiff.edits(from: item.text, to: out)
        let trim = CharacterSet.whitespacesAndNewlines
        #expect(
            applyAll(edits, to: item.text).trimmingCharacters(in: trim)
                == out.trimmingCharacters(in: trim),
            "row \(row.id)"
        )
        checked += 1
    }
    #expect(checked == outputs.count)
}

@Test func insertionAtTheEndSitsAtThePreviousTokensEnd() {
    let edits = TextDiff.edits(from: "a b", to: "a b c")
    #expect(edits.count == 1)
    #expect(edits[0].tokenSpan == 2..<2)
    #expect(edits[0].range == TextRange(location: 3, length: 0))
}

@Test func insertionIntoEmptyTextSitsAtZero() {
    let edits = TextDiff.edits(from: "", to: "a")
    #expect(edits.count == 1)
    #expect(edits[0].range == TextRange(location: 0, length: 0))
}

@Test("A deletion at the end writes the preceding unchanged token in place of both",
      arguments: [("See you you", "See you", "you you", "you"), ("Thanks!!", "Thanks!", "!!", "!")])
func aDeletionAtTheEndWritesItsNeighbour(_ original: String, _ revised: String, _ written: String, _ text: String) throws {
    let edit = try #require(TextDiff.edits(from: original, to: revised).first)
    #expect(edit.spliceText.isEmpty)
    #expect(substring(original, edit.writeRange) == written)
    #expect(edit.writeText == text)
    #expect(write(edit, to: original) == revised)
}

@Test func aDeletionAtTheStartWritesTheFollowingUnchangedToken() throws {
    let edit = try #require(TextDiff.edits(from: "Hello hello there", to: "hello there").first)
    #expect(substring("Hello hello there", edit.writeRange) == "Hello hello")
    #expect(edit.writeText == "hello")
    #expect(edit.range == TextRange(location: 0, length: 5))
}

@Test func aDeletionBetweenWordsWritesItsSpliceAsItIs() throws {
    let edit = try #require(TextDiff.edits(from: "We saw the the cat", to: "We saw the cat").first)
    #expect(edit.spliceText == " ")
    #expect(edit.writeRange == edit.spliceRange)
    #expect(edit.writeText == edit.spliceText)
}

@Test func everyWriteIsNonEmptyAndReproducesTheRevisedText() throws {
    let cases: [EvalCase] = try EvalScorer.loadJSONL(Fixtures.url("testset"))
    let outputs: [EvalOutput] = try EvalScorer.loadJSONL(Fixtures.url("out-apple-v3"))
    let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
    for row in outputs {
        guard let out = row.output, let item = byID[row.id] else { continue }
        let edits = TextDiff.edits(from: item.text, to: out)
        let written = edits.reversed().reduce(item.text) { write($1, to: $0) }
        let trim = CharacterSet.whitespacesAndNewlines
        #expect(written.trimmingCharacters(in: trim) == out.trimmingCharacters(in: trim), "row \(row.id)")
        #expect(edits.allSatisfy { !$0.writeText.isEmpty }, "row \(row.id)")
    }
}
