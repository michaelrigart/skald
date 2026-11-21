import Foundation
import Testing
@testable import SkaldCore
import struct SkaldCore.Issue
import struct SkaldCore.TextRange

private let fieldA = FieldID(app: "app", token: "a")
private let fieldB = FieldID(app: "app", token: "b")

private func wholeSnapshot(_ text: String, field: FieldID = fieldA) -> FieldSnapshot {
    FieldSnapshot(field: field, text: text, offset: 0, selection: TextRange(location: 0, length: 0), totalLength: text.utf16.count)
}

private func windowSnapshot(_ full: String, _ window: TextRange, field: FieldID = fieldA) -> FieldSnapshot {
    let text = (full as NSString).substring(with: NSRange(location: window.location, length: window.length))
    return FieldSnapshot(field: field, text: text, offset: window.location, selection: TextRange(location: window.location, length: 0), totalLength: full.utf16.count)
}

private func makeIssue(
    key: ParagraphKey,
    parent: Paragraph,
    chunk: Paragraph? = nil,
    replacing word: String,
    with correction: String,
    source: IssueSource = .spelling
) -> Issue {
    let chunk = chunk ?? parent
    let edit = TextDiff.edits(from: chunk.text, to: chunk.text.replacingOccurrences(of: word, with: correction))[0]
    return Issue(key: key, parent: parent, chunk: chunk, edit: edit, source: source, language: .en)
}

private func issue(in snapshot: FieldSnapshot, paragraph index: Int = 0, replacing word: String, with correction: String, source: IssueSource = .spelling) -> Issue {
    let (key, parent) = ParagraphKeys.keyed(snapshot)[index]
    return makeIssue(key: key, parent: parent, replacing: word, with: correction, source: source)
}

private func issue(in snapshot: FieldSnapshot, revisedTo revised: String, source: IssueSource) -> Issue {
    let (key, parent) = ParagraphKeys.keyed(snapshot)[0]
    let edit = TextDiff.edits(from: parent.text, to: revised)[0]
    return Issue(key: key, parent: parent, chunk: parent, edit: edit, source: source, language: .en)
}

private func longParagraph() -> String {
    (0..<10).map { "Teh\($0) " + String(repeating: "x", count: 293) + ". " }.joined()
}

@Test func modelResultWithdrawsSpellingIssuesItLeftUnchanged() {
    let text = "Ik heb reviewt en onmiddelijk gedaan"
    let snapshot = wholeSnapshot(text)
    let key = ParagraphKeys.keyed(snapshot)[0].0
    var tracker = IssueTracker()
    tracker.setSpelling([
        issue(in: snapshot, replacing: "reviewt", with: "reviewed"),
        issue(in: snapshot, replacing: "onmiddelijk", with: "onmiddellijk"),
    ], for: key)
    tracker.setModel([issue(in: snapshot, replacing: "onmiddelijk", with: "onmiddellijk", source: .model)], for: key)
    let words = tracker.visible(in: fieldA).map(\.word)
    #expect(!words.contains("reviewt"))
    #expect(words.filter { $0 == "onmiddelijk" }.count == 2)
}

@Test func modelReplacementOnTheSameWordKeepsTheSpellingIssue() {
    let snapshot = wholeSnapshot("a teh b")
    let key = ParagraphKeys.keyed(snapshot)[0].0
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: snapshot, replacing: "teh", with: "the")], for: key)
    tracker.setModel([issue(in: snapshot, replacing: "teh", with: "the", source: .model)], for: key)
    #expect(tracker.visible(in: fieldA).count == 2)
}

@Test func modelInsertionOnTheWordBoundaryWithdrawsTheSpellingIssue() {
    let snapshot = wholeSnapshot("Northwind reviewt")
    let key = ParagraphKeys.keyed(snapshot)[0].0
    let insertion = issue(in: snapshot, revisedTo: "Northwind reviewt.", source: .model)
    #expect(insertion.edit.range == TextRange(location: 17, length: 0))
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: snapshot, replacing: "reviewt", with: "reviewed")], for: key)
    tracker.setModel([insertion], for: key)
    #expect(tracker.visible(in: fieldA).map(\.word) == [""])
}

@Test func withdrawalDoesNotDependOnArrivalOrder() {
    let snapshot = wholeSnapshot("Ik heb reviewt en onmiddelijk gedaan")
    let key = ParagraphKeys.keyed(snapshot)[0].0
    let spelling = [
        issue(in: snapshot, replacing: "reviewt", with: "reviewed"),
        issue(in: snapshot, replacing: "onmiddelijk", with: "onmiddellijk"),
    ]

    var empty = IssueTracker()
    empty.setModel([], for: key)
    empty.setSpelling(spelling, for: key)
    #expect(empty.visible(in: fieldA).isEmpty)

    var partial = IssueTracker()
    partial.setModel([issue(in: snapshot, replacing: "onmiddelijk", with: "onmiddellijk", source: .model)], for: key)
    partial.setSpelling(spelling, for: key)
    let words = partial.visible(in: fieldA).map(\.word)
    #expect(!words.contains("reviewt"))
    #expect(words.filter { $0 == "onmiddelijk" }.count == 2)
}

@Test func clearingAKeyForgetsItsModelResult() {
    let snapshot = wholeSnapshot("Ik heb reviewt")
    let key = ParagraphKeys.keyed(snapshot)[0].0
    var tracker = IssueTracker()
    tracker.setModel([], for: key)
    tracker.clear(key)
    tracker.setSpelling([issue(in: snapshot, replacing: "reviewt", with: "reviewed")], for: key)
    #expect(tracker.visible(in: fieldA).count == 1)

    tracker.clear(key)
    tracker.setModel([], for: key)
    tracker.clear()
    tracker.setSpelling([issue(in: snapshot, replacing: "reviewt", with: "reviewed")], for: key)
    #expect(tracker.visible(in: fieldA).count == 1)
}

@Test func revalidateForgetsTheModelResultOfAVanishedParagraph() {
    let snapshot = wholeSnapshot("Ik heb reviewt\nsecond")
    let key = ParagraphKeys.keyed(snapshot)[0].0
    var tracker = IssueTracker()
    tracker.setModel([], for: key)
    #expect(tracker.revalidate(wholeSnapshot("second")) == [key])
    tracker.setSpelling([issue(in: snapshot, replacing: "reviewt", with: "reviewed")], for: key)
    #expect(tracker.visible(in: fieldA).count == 1)
}

@Test func revalidateDropsIssuesWhenTheParagraphChangedAndReportsTheirKeys() {
    let before = wholeSnapshot("They is ready\nanother wrng line")
    let keyed = ParagraphKeys.keyed(before)
    var tracker = IssueTracker()
    tracker.setSpelling([
        issue(in: before, paragraph: 0, replacing: "is", with: "are"),
        issue(in: before, paragraph: 0, replacing: "They", with: "These"),
    ], for: keyed[0].0)
    tracker.setSpelling([issue(in: before, paragraph: 1, replacing: "wrng", with: "wrong")], for: keyed[1].0)
    let dropped = tracker.revalidate(wholeSnapshot("He is ready\nanother wrng line"))
    #expect(dropped == [keyed[0].0])
    #expect(tracker.visible(in: fieldA).map(\.word) == ["wrng"])
}

@Test func revalidateDropsAnIssueWhenTheTextOnlyChangedItsUnicodeEncoding() {
    let composed = wholeSnapshot("caf\u{E9} teh report is ready")
    let decomposed = wholeSnapshot("cafe\u{301} teh report is ready")
    let key = ParagraphKeys.keyed(composed)[0].0
    #expect(composed.text == decomposed.text)
    #expect(key != ParagraphKeys.keyed(decomposed)[0].0)
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: composed, replacing: "teh", with: "the")], for: key)
    #expect(tracker.revalidate(decomposed) == [key])
    #expect(tracker.visible(in: fieldA).isEmpty)
}

@Test func textInsertedAboveMovesTheIssue() {
    let before = wholeSnapshot("They is ready")
    let key = ParagraphKeys.keyed(before)[0].0
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: before, replacing: "is", with: "are")], for: key)
    #expect(tracker.visible(in: fieldA)[0].fieldRange == TextRange(location: 5, length: 2))
    let dropped = tracker.revalidate(wholeSnapshot("Intro\nThey is ready"))
    #expect(dropped.isEmpty)
    let moved = tracker.visible(in: fieldA)[0]
    #expect(moved.fieldRange == TextRange(location: 11, length: 2))
    #expect(moved.parent.range == TextRange(location: 6, length: 13))
    #expect(moved.expected == ExpectedText(range: TextRange(location: 6, length: 13), text: "They is ready"))
}

@Test func fieldsWithIdenticalTextKeepSeparateIssues() {
    let a = wholeSnapshot("They is ready", field: fieldA)
    let b = wholeSnapshot("They is ready", field: fieldB)
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: a, replacing: "is", with: "are")], for: ParagraphKeys.keyed(a)[0].0)
    #expect(tracker.visible(in: fieldB).isEmpty)
    tracker.setSpelling([issue(in: b, replacing: "ready", with: "ok")], for: ParagraphKeys.keyed(b)[0].0)
    #expect(tracker.visible(in: fieldA).map(\.word) == ["is"])
    #expect(tracker.visible(in: fieldB).map(\.word) == ["ready"])
    tracker.revalidate(wholeSnapshot("changed", field: fieldA))
    #expect(tracker.visible(in: fieldA).isEmpty)
    #expect(tracker.visible(in: fieldB).map(\.word) == ["ready"])
}

@Test func issueOnTheFirstOccurrenceStaysOnIt() {
    let text = "They is ready\nok\nThey is ready"
    let snapshot = wholeSnapshot(text)
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: snapshot, paragraph: 0, replacing: "is", with: "are")], for: ParagraphKeys.keyed(snapshot)[0].0)
    tracker.revalidate(snapshot)
    #expect(tracker.visible(in: fieldA).map(\.fieldRange) == [TextRange(location: 5, length: 2)])
    tracker.revalidate(wholeSnapshot("Intro\n" + text))
    #expect(tracker.visible(in: fieldA).map(\.fieldRange) == [TextRange(location: 11, length: 2)])
}

@Test func ignoredIssueDoesNotComeBackForTheSameKey() {
    let snapshot = wholeSnapshot("Ik heb onmiddelijk gedaan")
    let key = ParagraphKeys.keyed(snapshot)[0].0
    func correction(_ source: IssueSource) -> Issue {
        issue(in: snapshot, replacing: "onmiddelijk", with: "onmiddellijk", source: source)
    }
    func other(_ source: IssueSource) -> Issue {
        issue(in: snapshot, replacing: "gedaan", with: "gedaen", source: source)
    }
    var tracker = IssueTracker()
    let spelling = correction(.spelling)
    tracker.setSpelling([spelling, other(.spelling)], for: key)
    tracker.setModel([correction(.model), other(.model)], for: key)
    #expect(tracker.visible(in: fieldA).map(\.word).filter { $0 == "onmiddelijk" }.count == 2)

    tracker.ignore(spelling.id)
    #expect(tracker.visible(in: fieldA).map(\.word) == ["gedaan", "gedaan"])

    tracker.setSpelling([correction(.spelling), other(.spelling)], for: key)
    tracker.setModel([correction(.model), other(.model)], for: key)
    #expect(tracker.visible(in: fieldA).map(\.word) == ["gedaan", "gedaan"])
    tracker.clear()
    tracker.setModel([correction(.model)], for: key)
    #expect(tracker.visible(in: fieldA).isEmpty)
}

@Test func removeAllWordIsCaseInsensitiveAcrossFields() {
    let a = wholeSnapshot("Talos is up", field: fieldA)
    let b = wholeSnapshot("run talos now", field: fieldB)
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: a, replacing: "Talos", with: "Talus"), issue(in: a, replacing: "up", with: "down")], for: ParagraphKeys.keyed(a)[0].0)
    tracker.setSpelling([issue(in: b, replacing: "talos", with: "talus")], for: ParagraphKeys.keyed(b)[0].0)
    #expect(tracker.removeAll(word: "Talos") == [ParagraphKeys.keyed(a)[0].0, ParagraphKeys.keyed(b)[0].0])
    #expect(tracker.visible(in: fieldA).map(\.word) == ["up"])
    #expect(tracker.visible(in: fieldB).isEmpty)
}

@Test func removeAllWhereReportsEachDroppedKeyOnce() {
    let snapshot = wholeSnapshot("Talos is up\nthe rest")
    let keyed = ParagraphKeys.keyed(snapshot)
    var tracker = IssueTracker()
    tracker.setSpelling([
        issue(in: snapshot, replacing: "Talos", with: "Talus"),
        issue(in: snapshot, replacing: "up", with: "down"),
    ], for: keyed[0].0)
    tracker.setSpelling([issue(in: snapshot, paragraph: 1, replacing: "rest", with: "best")], for: keyed[1].0)
    #expect(tracker.removeAll { $0.key == keyed[0].0 } == [keyed[0].0])
    #expect(tracker.visible(in: fieldA).map(\.word) == ["rest"])
    #expect(tracker.removeAll { _ in false } == [])
}

@Test func suspendedFieldShowsNothingUntilRevalidate() {
    let snapshot = wholeSnapshot("They is ready")
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: snapshot, replacing: "is", with: "are")], for: ParagraphKeys.keyed(snapshot)[0].0)
    tracker.suspend(fieldA)
    #expect(tracker.visible(in: fieldA).isEmpty)
    tracker.revalidate(snapshot)
    #expect(tracker.visible(in: fieldA).count == 1)
}

@Test func issuesOnEveryChunkSurviveAndMoveTogether() {
    let long = longParagraph()
    let snapshot = wholeSnapshot(long)
    let chunked = ParagraphKeys.chunkKeys(snapshot, caret: 0)
    #expect(chunked.count == 3)
    var tracker = IssueTracker()
    for (index, entry) in chunked.enumerated() {
        let word = "Teh\(index * 4)"
        tracker.setSpelling([makeIssue(key: entry.0, parent: entry.parent, chunk: entry.chunk, replacing: word, with: "The\(index * 4)")], for: entry.0)
    }
    let before = tracker.visible(in: fieldA).map(\.fieldRange)
    #expect(before.map(\.location) == [0, 1200, 2400])
    #expect(tracker.revalidate(snapshot).isEmpty)
    #expect(tracker.visible(in: fieldA).map(\.fieldRange) == before)
    #expect(tracker.revalidate(wholeSnapshot("Intro\n" + long)).isEmpty)
    #expect(tracker.visible(in: fieldA).map(\.fieldRange.location) == [6, 1206, 2406])
}

@Test func issuesOutsideTheWindowSurviveUntilTheWindowReturns() {
    let filler = String(repeating: String(repeating: "a", count: 99) + "\n", count: 590)
    let full = "They is ready\n" + filler + "Zij zijn klaar"
    let total = full.utf16.count
    let windowA = TextRange(location: 0, length: 10_000)
    let windowB = ReadWindow.range(totalLength: total, caret: total - 5, limit: 100, radius: 5_000)
    #expect(windowB.location > windowA.end)

    let first = windowSnapshot(full, windowA)
    let keyA = ParagraphKeys.keyed(first)[0].0
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: first, replacing: "is", with: "are")], for: keyA)

    let dropped = tracker.revalidate(windowSnapshot(full, windowB))
    #expect(dropped.isEmpty)
    #expect(tracker.visible(in: fieldA).map(\.fieldRange) == [TextRange(location: 5, length: 2)])

    #expect(tracker.revalidate(windowSnapshot(full, windowA)).isEmpty)
    #expect(tracker.visible(in: fieldA).map(\.word) == ["is"])
}

@Test func issuesInsideTheWindowAreDroppedWhenTheirParagraphIsGone() {
    let full = "They is ready\n" + String(repeating: "b\n", count: 20_000)
    let first = windowSnapshot(full, TextRange(location: 0, length: 100))
    let key = ParagraphKeys.keyed(first)[0].0
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: first, replacing: "is", with: "are")], for: key)
    let edited = "He is ready\n" + String(repeating: "b\n", count: 20_000)
    #expect(tracker.revalidate(windowSnapshot(edited, TextRange(location: 0, length: 100))) == [key])
    #expect(tracker.visible(in: fieldA).isEmpty)
}

@Test func windowedModelResultSurvivesOutOfViewAndDropsWhenItsParagraphIsEditedAway() {
    let filler = String(repeating: String(repeating: "a", count: 99) + "\n", count: 590)
    let full = "They is ready\n" + filler + "Zij zijn klaar"
    let total = full.utf16.count
    let windowA = TextRange(location: 0, length: 10_000)
    let windowB = ReadWindow.range(totalLength: total, caret: total - 5, limit: 100, radius: 5_000)
    #expect(windowB.location > windowA.end)

    let first = windowSnapshot(full, windowA)
    let keyA = ParagraphKeys.keyed(first)[0].0
    #expect(keyA.position == .location(0))
    let flag = { issue(in: first, replacing: "is", with: "are") }
    var tracker = IssueTracker()
    tracker.setModel([], for: keyA)

    #expect(tracker.revalidate(windowSnapshot(full, windowB)).isEmpty)
    tracker.setSpelling([flag()], for: keyA)
    #expect(tracker.visible(in: fieldA).isEmpty)

    let edited = "He is ready\n" + filler + "Zij zijn klaar"
    #expect(tracker.revalidate(windowSnapshot(edited, windowA)) == [keyA])
    tracker.setSpelling([flag()], for: keyA)
    #expect(tracker.visible(in: fieldA).map(\.word) == ["is"])
}

@Test func anOccurrenceKeyIssueFarDownIsDroppedWhenTheFieldGrowsPastTheReadLimit() {
    let filler = String(repeating: String(repeating: "a", count: 99) + "\n", count: 150)
    let whole = "Intro\n" + filler + "They is ready"
    let before = wholeSnapshot(whole)
    let key = ParagraphKeys.keyed(before).last!.0
    #expect(key.position == .occurrence(0))
    var tracker = IssueTracker()
    tracker.setSpelling([issue(in: before, paragraph: 151, replacing: "is", with: "are")], for: key)
    #expect(tracker.visible(in: fieldA).count == 1)

    let grown = "Intro\n" + filler + String(repeating: "b\n", count: 20_000) + "They is ready"
    let window = TextRange(location: 0, length: 1_000)
    #expect(tracker.revalidate(windowSnapshot(grown, window)) == [key])
    #expect(tracker.visible(in: fieldA).isEmpty)
}
