import Testing
@testable import SkaldCore

private func score(_ run: String) throws -> EvalScore {
    let cases: [EvalCase] = try EvalScorer.loadJSONL(Fixtures.url("testset"))
    let outputs: [EvalOutput] = try EvalScorer.loadJSONL(Fixtures.url(run))
    return EvalScorer.score(cases, outputs)
}

@Test func appleV3MatchesTheSpike() throws {
    let s = try score("out-apple-v3")
    #expect((s.tp, s.fp, s.fn) == (34, 6, 1))
    #expect((s.cleanFlagged, s.cleanTotal) == (2, 12))
    #expect(abs(s.p50Ms - 454) <= 1)
    #expect(abs(s.p90Ms - 554) <= 1)
}

@Test func appleV3RatiosFollowTheSpikeFormulas() throws {
    let s = try score("out-apple-v3")
    let p = 34.0 / 40.0, r = 34.0 / 35.0
    #expect(abs(s.precision - p) < 1e-9)
    #expect(abs(s.recall - r) < 1e-9)
    #expect(abs(s.f05 - 1.25 * p * r / (0.25 * p + r)) < 1e-9)
}

@Test func appleMatchesTheSpike() throws {
    let s = try score("out-apple")
    #expect((s.tp, s.fp, s.fn) == (33, 8, 2))
}

@Test func qwenAneMatchesTheSpike() throws {
    let s = try score("out-qwen-ane")
    #expect((s.tp, s.fp, s.fn) == (16, 3, 19))
}

@Test func qwenGpuMatchesTheSpike() throws {
    let s = try score("out-qwen-gpu")
    #expect((s.tp, s.fp, s.fn) == (18, 2, 17))
}

@Test func appleV3ByLanguageMatchesTheSpike() throws {
    let cases: [EvalCase] = try EvalScorer.loadJSONL(Fixtures.url("testset"))
    let outputs: [EvalOutput] = try EvalScorer.loadJSONL(Fixtures.url("out-apple-v3"))
    let by = EvalScorer.byLanguage(cases, outputs)
    func triple(_ l: Language) -> [Int] { by[l].map { [$0.tp, $0.fp, $0.fn] } ?? [] }
    #expect(triple(.en) == [17, 0, 0])
    #expect(triple(.nl) == [8, 2, 1])
    #expect(triple(.fr) == [9, 4, 0])
}

@Test func missingOutputCountsEveryReferenceEditAsMissed() {
    let c = EvalCase(id: "x", lang: .en, text: "a b", ref: "a c")
    let o = EvalOutput(id: "x", lang: .en, output: nil, error: "boom", ms: 1)
    let s = EvalScorer.score([c], [o])
    #expect((s.tp, s.fp, s.fn) == (0, 0, 1))
}
