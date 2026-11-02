import Testing
@testable import SkaldCore

@Test func apostropheSplitsContractions() {
    #expect(Tokenizer.tokens(in: "I've went").map(\.text) == ["I", "'", "ve", "went"])
}

@Test func rangesAreUTF16NotCharacterOffsets() {
    let ik = Tokenizer.tokens(in: "👍🏽 Ik").last
    #expect(ik?.text == "Ik")
    #expect(ik?.range == TextRange(location: 5, length: 2))
}
