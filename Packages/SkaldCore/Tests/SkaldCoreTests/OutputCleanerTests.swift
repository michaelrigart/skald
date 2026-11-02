import Foundation
import Testing
@testable import SkaldCore

@Test func wrappingQuotesTheInputLackedAreRemoved() {
    #expect(OutputCleaner.clean("\"Fixed.\"", input: "Fixed?") == "Fixed.")
    #expect(OutputCleaner.clean("“Fixed.”", input: "Fixed?") == "Fixed.")
    #expect(OutputCleaner.clean("«Fixed.»", input: "Fixed?") == "Fixed.")
    #expect(OutputCleaner.clean("« Fixed. »", input: "Fixed?") == "Fixed.")
}

@Test func quotesTheInputHadAreKept() {
    #expect(OutputCleaner.clean("\"Fixed.\"", input: "\"Fixed?\"") == "\"Fixed.\"")
    #expect(OutputCleaner.clean("“Fixed.”", input: "  “Fixed?”") == "“Fixed.”")
}

@Test func quotesThatDoNotWrapTheWholeOutputAreKept() {
    #expect(OutputCleaner.clean("\"A\" and \"B\"", input: "A and B") == "\"A\" and \"B\"")
    #expect(OutputCleaner.clean("He said \"hi\"", input: "He sed hi") == "He said \"hi\"")
}

@Test func anEmptyThinkBlockIsRemoved() {
    #expect(OutputCleaner.clean("<think></think>\nHello", input: "Helo") == "Hello")
}

@Test func aThinkBlockWithReasoningIsRemoved() {
    #expect(OutputCleaner.clean("<think>\nThe typo is in the first word.\n</think>\n\nHello", input: "Helo") == "Hello")
}

@Test func aThinkBlockThatIsNotFirstIsKept() {
    #expect(OutputCleaner.clean("Hello <think></think>", input: "Helo") == "Hello <think></think>")
}

@Test(arguments: [
    "Corrected text: Hallo",
    "corrected: Hallo",
    "CORRECTED TEXT :Hallo",
    "Here is the corrected text:\nHallo",
    "Here is the corrected text: Hallo",
])
private func aPreambleIsRemoved(_ output: String) {
    #expect(OutputCleaner.clean(output, input: "Halo") == "Hallo")
}

@Test func aPreambleIsRemovedOnceAndOnlyAtTheStart() {
    #expect(OutputCleaner.clean("Corrected text: Corrected text: Hallo", input: "Halo") == "Corrected text: Hallo")
    #expect(OutputCleaner.clean("Hallo. Corrected text: ok", input: "Halo") == "Hallo. Corrected text: ok")
}

@Test func aPreambleAndWrappingQuotesAreBothRemoved() {
    #expect(OutputCleaner.clean("Corrected text: \"Hallo\"", input: "Halo") == "Hallo")
}

@Test func aCodeFenceTheInputLackedIsRemoved() {
    #expect(OutputCleaner.clean("```\nHallo\n```", input: "Halo") == "Hallo")
    #expect(OutputCleaner.clean("```text\nHallo wereld\n```", input: "Halo wereld") == "Hallo wereld")
}

@Test func aCodeFenceTheInputHadIsKept() {
    let input = "```\nlet x = 1\n```"
    #expect(OutputCleaner.clean("```\nlet x = 2\n```", input: input) == "```\nlet x = 2\n```")
}

@Test func surroundingWhitespaceIsTrimmed() {
    #expect(OutputCleaner.clean("\n  Hallo  \n", input: "Halo") == "Hallo")
}

@Test func anUnchangedOutputStaysUnchanged() {
    #expect(OutputCleaner.clean("lgtm", input: "lgtm") == "lgtm")
}

@Test func theStoredSpikeOutputsPassThroughUnchanged() throws {
    let cases: [EvalCase] = try EvalScorer.loadJSONL(Fixtures.url("testset"))
    let outputs: [EvalOutput] = try EvalScorer.loadJSONL(Fixtures.url("out-apple-v3"))
    for row in outputs {
        guard let c = cases.first(where: { $0.id == row.id }), let output = row.output else { continue }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(OutputCleaner.clean(output, input: c.text) == trimmed, "\(row.id)")
    }
}
