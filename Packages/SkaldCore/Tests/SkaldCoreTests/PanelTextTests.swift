import Testing
@testable import SkaldCore

private func split(_ text: String) -> [[String]] {
    PanelText.paragraphs(text).map { [$0.text, $0.separator] }
}

@Test func twoParagraphsSplitWithTheirSeparators() {
    let parts = PanelText.paragraphs("Hi there.\n\nHallo daar.")
    #expect(parts.count == 2)
    #expect(parts[0].text == "Hi there." && parts[0].separator == "\n\n")
    #expect(parts[1].text == "Hallo daar." && parts[1].separator == "")
    #expect(PanelText.reassemble(parts) == "Hi there.\n\nHallo daar.")
}

@Test func crlfSeparatorsSurvive() {
    let parts = PanelText.paragraphs("One\r\n\r\nTwo\r\nThree")
    #expect(split("One\r\n\r\nTwo\r\nThree") == [["One", "\r\n\r\n"], ["Two", "\r\n"], ["Three", ""]])
    #expect(PanelText.reassemble(parts) == "One\r\n\r\nTwo\r\nThree")
}

@Test func everyLineBreakKindSplits() {
    #expect(split("a\nb\rc\u{2028}d\u{2029}e") == [["a", "\n"], ["b", "\r"], ["c", "\u{2028}"], ["d", "\u{2029}"], ["e", ""]])
}

@Test func whitespaceOnlyLinesBetweenBreaksJoinTheSeparator() {
    #expect(split("a\n  \n\t\nb") == [["a", "\n  \n\t\n"], ["b", ""]])
    #expect(split("a\n  b") == [["a", "\n"], ["  b", ""]])
}

@Test func leadingBreaksBecomeAFirstPartWithEmptyText() {
    #expect(split("\n\nHi") == [["", "\n\n"], ["Hi", ""]])
    #expect(split("  \nHi") == [["", "  \n"], ["Hi", ""]])
}

@Test func trailingBreaksAndWhitespaceStayInTheLastSeparator() {
    #expect(split("Hi.\n") == [["Hi.", "\n"]])
    #expect(split("Hi.\n\n   ") == [["Hi.", "\n\n   "]])
    #expect(split("Hi.   ") == [["Hi.   ", ""]])
}

@Test func emptyAndBreakOnlyInputs() {
    #expect(split("") == [])
    #expect(split("\n\r\n") == [["", "\n\r\n"]])
    #expect(split("   ") == [["", "   "]])
}

@Test func reassembleGivesBackTheExactInputForTrickyStrings() {
    let samples = [
        "", "\n", "\n\nHi", "Hi\n\n", "Hi.  \n\nHallo.  ", "  \n  \n", "a\r\nb\nc\r\n\r\nd",
        "a\u{2029}\u{2029}b\u{2028}c", "a\r\rb", "a\n\r\nb", "\u{2029}x\u{2029}", "tab\t\n\tindented\n \n x",
        "emoji 👍🏽\n\nnaïve café\r\n", "no breaks at all", " \u{00A0}\n\u{00A0}", "cafe\u{301}\n\nx",
    ]
    for sample in samples {
        let parts = PanelText.paragraphs(sample)
        #expect(Array(PanelText.reassemble(parts).utf8) == Array(sample.utf8))
        #expect(parts.allSatisfy { $0.text.unicodeScalars.allSatisfy { !"\n\r\u{2028}\u{2029}".unicodeScalars.contains($0) } })
    }
}

@Test func editedTextsKeepTheirOriginalSeparators() {
    var parts = PanelText.paragraphs("Hi there.\r\n\r\nHallo daar.")
    parts[1].text = "Hallo daar!"
    #expect(PanelText.reassemble(parts) == "Hi there.\r\n\r\nHallo daar!")
}
