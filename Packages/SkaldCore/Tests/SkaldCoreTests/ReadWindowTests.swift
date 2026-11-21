import Testing
@testable import SkaldCore

@Test func windowCentersOnTheCaret() {
    #expect(ReadWindow.range(totalLength: 60_000, caret: 30_000) == TextRange(location: 25_000, length: 10_000))
}

@Test func windowIsPinnedToTheStart() {
    #expect(ReadWindow.range(totalLength: 60_000, caret: 1_000) == TextRange(location: 0, length: 10_000))
}

@Test func windowIsPinnedToTheEnd() {
    #expect(ReadWindow.range(totalLength: 60_000, caret: 59_500) == TextRange(location: 50_000, length: 10_000))
}

@Test func fieldWithinTheLimitIsReadWhole() {
    #expect(ReadWindow.range(totalLength: 15_000, caret: 7_000) == TextRange(location: 0, length: 15_000))
}

@Test func aFieldAtTheLimitIsReadWhole() {
    #expect(ReadWindow.limit == 20_000)
    #expect(ReadWindow.range(totalLength: ReadWindow.limit, caret: 0) == TextRange(location: 0, length: 20_000))
    #expect(ReadWindow.range(totalLength: ReadWindow.limit + 1, caret: 0).length == 10_000)
}
