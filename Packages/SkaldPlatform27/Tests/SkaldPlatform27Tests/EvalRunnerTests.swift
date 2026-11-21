import Foundation
import SkaldCore
import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27

struct EvalOptionsTests {
    @Test("Every option is read; the guard defaults to on and the output to none")
    func parsesOptions() throws {
        #expect(try EvalOptions.parse(["--set", "Eval/heldout.jsonl", "--mode", "model"])
            == EvalOptions(set: "Eval/heldout.jsonl", mode: .model, guardOn: true, out: nil))
        #expect(try EvalOptions.parse(["--mode", "spelling", "--guard", "off", "--out", "build/eval/s.jsonl", "--set", "s.jsonl"])
            == EvalOptions(set: "s.jsonl", mode: .spelling, guardOn: false, out: "build/eval/s.jsonl"))
    }

    @Test func parsesClaudeAndReplayOptions() throws {
        #expect(try EvalOptions.parse(["--set", "s.jsonl", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "1.5", "--out", "o.jsonl"])
            == EvalOptions(set: "s.jsonl", mode: .claude, guardOn: true, out: "o.jsonl", claudeModel: "claude-haiku-5-5", maxCost: 1.5, claudeRequest: .typing))
        #expect(try EvalOptions.parse(["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "1", "--out", "o", "--thinking", "on", "--fallbacks", "on"]).claudeRequest
            == ClaudeRequestOptions(thinking: .modelDefault, serverFallbacks: true))
        for id in ["claude-sonnet-5-5", "claude-opus-5-5"] {
            #expect(try EvalOptions.parse(["--set", "s", "--mode", "claude", "--claude-model", id, "--max-cost", "1", "--out", "o", "--thinking", "on"]).claudeRequest.thinking
                == .modelDefault)
        }
        #expect(try EvalOptions.parse(["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "1", "--out", "o", "--thinking", "off"]).claudeRequest.thinking
            == .disabled)
        #expect(try EvalOptions.parse(["--set", "s", "--mode", "replay", "--outputs", "r.jsonl", "--guard", "off"])
            == EvalOptions(set: "s", mode: .replay, guardOn: false, out: nil, outputs: "r.jsonl"))
    }

    @Test("Missing, unknown and malformed options are usage errors", arguments: [
        ([], "--set is required"),
        (["--set", "s.jsonl"], "--mode is required"),
        (["--set", "s.jsonl", "--mode", "fast"], "--mode is model, spelling, claude or replay"),
        (["--set", "s.jsonl", "--mode", "model", "--guard", "yes"], "--guard is on or off"),
        (["--set", "s.jsonl", "--mode", "model", "--verbose"], "unknown option --verbose"),
        (["--mode", "model", "--set"], "--set needs a value"),
        (["--set", "s", "--mode", "claude", "--max-cost", "1", "--out", "o"], "--mode claude needs --claude-model"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-4-5", "--max-cost", "1", "--out", "o"], "no price for claude-haiku-4-5"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--out", "o"], "--mode claude needs --max-cost"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "1"], "--mode claude needs --out, to keep the answers it pays for"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "0", "--out", "o"], "--max-cost is a dollar amount above 0 and at most 5"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "5.01", "--out", "o"], "--max-cost is a dollar amount above 0 and at most 5"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "x", "--out", "o"], "--max-cost is a dollar amount above 0 and at most 5"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "1", "--out", "o", "--thinking", "maybe"], "--thinking is on or off"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-haiku-5-5", "--max-cost", "1", "--out", "o", "--fallbacks", "yes"], "--fallbacks is on or off"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-opus-5-5", "--max-cost", "1", "--out", "o", "--thinking", "off"], "claude-opus-5-5 rejects disabled thinking; pass --thinking on"),
        (["--set", "s", "--mode", "claude", "--claude-model", "claude-sonnet-5-5", "--max-cost", "1", "--out", "o"], "claude-sonnet-5-5 rejects disabled thinking; pass --thinking on"),
        (["--set", "s", "--mode", "replay"], "--mode replay needs --outputs"),
        (["--set", "s", "--mode", "model", "--max-cost", "1"], "--claude-model, --max-cost, --thinking and --fallbacks are for --mode claude"),
        (["--set", "s", "--mode", "model", "--outputs", "r"], "--outputs is for --mode replay"),
    ] as [([String], String)])
    func usageErrors(_ example: ([String], String)) {
        #expect(throws: EvalUsageError(message: example.1)) { try EvalOptions.parse(example.0) }
    }
}

struct EvalApplyTests {
    @Test("Applying every edit of a diff rebuilds the revised text", arguments: [
        ("I've went through the logs and their is a problem.", "I've gone through the logs and there is a problem."),
        ("Hi Sarah thanks for the the fix", "Hi Sarah, thanks for the fix."),
        ("👍🏽 Ik heb de versie gedownloaded en getest", "👍🏽 Ik heb de versie gedownload en getest"),
        ("Ces la fin", "C'est la fin"),
    ])
    func appliesADiff(_ pair: (String, String)) {
        #expect(EvalRunner.apply(TextDiff.edits(from: pair.0, to: pair.1), to: pair.0) == pair.1)
    }

    @Test("Only the given edits are applied")
    func appliesASubset() {
        let text = "I've went through the logs and their is a problem."
        let edits = TextDiff.edits(from: text, to: "I've gone through the logs and there is a problem.")
        #expect(EvalRunner.apply([edits[1]], to: text) == "I've went through the logs and there is a problem.")
        #expect(EvalRunner.apply([], to: text) == text)
    }

    @Test("Two neighbouring spelling flags, each diffed on its own, both apply")
    func appliesNeighbouringFlags() {
        let text = "Plese recieve it."
        let first = TextDiff.edits(from: text, to: "Please recieve it.")
        let second = TextDiff.edits(from: text, to: "Plese receive it.")
        #expect(EvalRunner.apply(first + second, to: text) == "Please receive it.")
    }
}

/// Scores `tp` fixed errors, `fp` flagged clean cases and `fn` missed errors, one case each, through the real scorer.
private func scored(tp: Int = 0, fp: Int = 0, fn: Int = 0, latencies: [Double] = []) -> EvalScore {
    var cases: [EvalCase] = [], outputs: [EvalOutput] = []
    func add(_ text: String, _ ref: String, _ output: String) {
        let id = "c\(cases.count)"
        cases.append(EvalCase(id: id, lang: .en, text: text, ref: ref))
        outputs.append(EvalOutput(id: id, lang: .en, output: output, error: nil, ms: latencies.isEmpty ? 500 : latencies[cases.count - 1]))
    }
    for _ in 0..<tp { add("their is", "there is", "there is") }
    for _ in 0..<fp { add("it is", "it is", "it was") }
    for _ in 0..<fn { add("their is", "there is", "their is") }
    return EvalScorer.score(cases, outputs)
}

struct EvalBarTests {
    @Test("Precision must reach 0.95 in both modes")
    func precision() {
        #expect(EvalBar.misses(scored(tp: 38, fp: 1, fn: 1), mode: .model).isEmpty)
        #expect(EvalBar.misses(scored(tp: 19, fp: 1), mode: .model).isEmpty)
        #expect(EvalBar.misses(scored(tp: 16, fp: 1), mode: .model) == [.precision])
        #expect(EvalBar.misses(scored(tp: 16, fp: 1), mode: .spelling) == [.precision])
    }

    @Test("At most one clean paragraph may be flagged on the model path")
    func cleanParagraphs() {
        #expect(EvalBar.misses(scored(tp: 40, fp: 2), mode: .model) == [.cleanParagraphs])
        #expect(EvalBar.misses(scored(tp: 40, fp: 2), mode: .spelling).isEmpty)
        #expect(EvalBar.misses(scored(tp: 40, fp: 2), mode: .claude) == [.cleanParagraphs])
        #expect(EvalBar.misses(scored(tp: 40, fp: 2), mode: .replay) == [.cleanParagraphs])
    }

    @Test("Recall must reach 0.90 on the model path only")
    func recall() {
        #expect(EvalBar.misses(scored(tp: 18, fn: 2), mode: .model).isEmpty)
        #expect(EvalBar.misses(scored(tp: 17, fn: 2), mode: .model) == [.recall])
        #expect(EvalBar.misses(scored(tp: 17, fn: 2), mode: .spelling).isEmpty)
        #expect(EvalBar.misses(scored(tp: 17, fn: 2), mode: .claude) == [.recall])
        #expect(EvalBar.misses(scored(tp: 17, fn: 2), mode: .replay) == [.recall])
    }

    @Test("With nothing proposed there is no false alarm, but every error is missed")
    func nothingProposed() {
        #expect(EvalBar.misses(scored(fn: 3), mode: .model) == [.recall])
        #expect(EvalBar.misses(scored(fn: 3), mode: .spelling).isEmpty)
    }

    @Test("A request error leaves its language without a verdict; otherwise the misses decide")
    func verdicts() {
        #expect(EvalBar.verdict(scored(tp: 20), errors: 1, mode: .model) == .noVerdict(errors: 1))
        #expect(EvalBar.verdict(scored(tp: 20), errors: 0, mode: .model) == .pass)
        #expect(EvalBar.verdict(scored(tp: 16, fp: 1), errors: 0, mode: .spelling) == .fail([.precision]))
    }

    @Test("p90 is the 18th of 20 latencies, and the model path needs it under one second")
    func latency() {
        let fast = Array(repeating: 100.0, count: 17)
        let under = scored(tp: 20, latencies: fast + [999, 5_000, 9_000])
        #expect(under.p90Ms == 999)
        #expect(EvalBar.misses(under, mode: .model).isEmpty)
        let over = scored(tp: 20, latencies: fast + [1_000, 5_000, 9_000])
        #expect(over.p90Ms == 1_000)
        #expect(EvalBar.misses(over, mode: .model) == [.latency])
        #expect(EvalBar.misses(over, mode: .spelling).isEmpty)
        #expect(EvalBar.misses(scored(tp: 20, latencies: fast + [1_999, 5_000, 9_000]), mode: .claude).isEmpty)
        #expect(EvalBar.misses(scored(tp: 20, latencies: fast + [2_000, 5_000, 9_000]), mode: .claude) == [.latency])
        #expect(EvalBar.misses(scored(tp: 20, latencies: fast + [9_000, 9_000, 9_000]), mode: .replay).isEmpty)
    }
}

private struct MappedDetector: LanguageDetecting {
    let answers: [String: Language]

    func detect(_ text: String, previous: Language?) -> Language? {
        answers[text] ?? previous
    }
}

private actor ScriptedEngine: Engine {
    nonisolated var kind: EngineKind { .thisMac }
    private let reply: Result<String, EngineFailure>
    private(set) var languages: [Language] = []

    init(_ reply: Result<String, EngineFailure>) {
        self.reply = reply
    }

    func run(_ r: EngineRequest) throws(EngineFailure) -> String {
        languages.append(r.language)
        return try reply.get()
    }
}

private struct ScriptedSpelling: SpellingChecking {
    let flags: [Edit]

    func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) async -> [Edit] {
        flags
    }
}

private struct NoFacts: WordOracle {
    func facts(for words: Set<String>, language: Language) async -> WordFacts {
        WordFacts()
    }
}

private struct Approves: EditConfirming {
    func confirm(_ edit: Edit, in paragraph: String, language: Language) async -> Bool? {
        true
    }
}

private func runner(
    _ mode: EvalMode,
    guardOn: Bool = true,
    detector: MappedDetector = MappedDetector(answers: [:]),
    engine: ScriptedEngine = ScriptedEngine(.failure(.failed)),
    replay: [String: String]? = nil,
    flags: [Edit] = []
) -> EvalRunner {
    EvalRunner(
        mode: mode, guardOn: guardOn, detector: detector, engine: engine, replay: replay,
        spelling: ScriptedSpelling(flags: flags), oracle: NoFacts(), confirmer: Approves()
    )
}

struct EvalRunnerPathTests {
    @Test("A missing or wrong detection counts as a language miss, and the check runs in the case's language")
    func languageFallback() async {
        let cases = [
            EvalCase(id: "right", lang: .en, text: "Thanks for the update.", ref: "Thanks for the update."),
            EvalCase(id: "wrong", lang: .en, text: "Thanks for the fix.", ref: "Thanks for the fix."),
            EvalCase(id: "none", lang: .en, text: "ok", ref: "ok"),
        ]
        let detector = MappedDetector(answers: ["Thanks for the update.": .en, "Thanks for the fix.": .nl])
        let engine = ScriptedEngine(.success("ok"))
        let run = await runner(.model, detector: detector, engine: engine).run(cases)
        #expect(run.languageMisses == ["wrong", "none"])
        #expect(await engine.languages == [.en, .en, .en])
    }

    @Test("A model result in another language is discarded whole")
    func translatedResult() async {
        let text = "The backup runs every night."
        let dutch = "De back-up draait elke nacht."
        let detector = MappedDetector(answers: [text: .en, dutch: .nl])
        let run = await runner(.model, detector: detector, engine: ScriptedEngine(.success(dutch)))
            .run([EvalCase(id: "x", lang: .en, text: text, ref: text)])
        #expect(run.outputs.map(\.output) == [text])
        #expect(run.discarded == ["x": .languageChanged])
    }

    @Test("The guard judges the model's edits when on; when off, the model's output is the result")
    func guardSwitch() async {
        let text = "ping me if the canary looks off"
        let item = EvalCase(id: "x", lang: .en, text: text, ref: text)
        let engine = ScriptedEngine(.success(text + "."))
        #expect(await runner(.model, engine: engine).run([item]).outputs.map(\.output) == [text])
        #expect(await runner(.model, guardOn: false, engine: engine).run([item]).outputs.map(\.output) == [text + "."])
    }

    @Test("An engine failure leaves no output and records the failure")
    func engineFailure() async {
        let run = await runner(.model, engine: ScriptedEngine(.failure(.timedOut)))
            .run([EvalCase(id: "x", lang: .en, text: "Their is a problem.", ref: "There is a problem.")])
        #expect(run.outputs.map(\.output) == [nil])
        #expect(run.outputs.map(\.error) == ["timedOut"])
    }

    @Test("The confirmer settles undecided model edits but never spelling flags")
    func confirmationOnlyOnTheModelPath() async {
        let text = "I will visit paris again."
        let fixed = "I will visit Paris again."
        let item = EvalCase(id: "x", lang: .en, text: text, ref: fixed)
        let model = await runner(.model, engine: ScriptedEngine(.success(fixed))).run([item])
        #expect(model.outputs.map(\.output) == [fixed])
        let spelling = await runner(.spelling, flags: TextDiff.edits(from: text, to: fixed)).run([item])
        #expect(spelling.outputs.map(\.output) == [text])
    }

    @Test("A spelling flag without a guess is dropped by the guard and applied without it")
    func spellingFlagWithoutAGuess() async {
        let text = "Dan stuur ik onmiddelijk de factuur."
        let flags = TextDiff.edits(from: text, to: "Dan stuur ik de factuur.")
        let item = EvalCase(id: "x", lang: .nl, text: text, ref: "Dan stuur ik onmiddellijk de factuur.")
        #expect(await runner(.spelling, flags: flags).run([item]).outputs.map(\.output) == [text])
        #expect(await runner(.spelling, guardOn: false, flags: flags).run([item]).outputs.map(\.output) == ["Dan stuur ik de factuur."])
    }
}

struct EvalClaudeRunnerTests {
    @Test func aReplayedCaseWithoutARecordedAnswerIsARequestError() async {
        let cases = [
            EvalCase(id: "a", lang: .nl, text: "Ik heb het gedownload.", ref: "Ik heb het gedownload."),
            EvalCase(id: "b", lang: .nl, text: "Dat klopt niet.", ref: "Dat klopt niet."),
        ]
        let run = await runner(.replay, guardOn: false, replay: ["a": "  Ik heb het gedownload.  "]).run(cases)
        #expect(run.outputs.map(\.output) == ["Ik heb het gedownload.", nil])
        #expect(run.outputs.map(\.error) == [nil, "failed"])
        let score = EvalScorer.score(cases, run.outputs)
        #expect(EvalBar.verdict(score, errors: run.outputs.filter { $0.error != nil }.count, mode: .replay) == .noVerdict(errors: 1))
    }

    @Test func theRawAnswerIsRecordedBeforeTheGuardAndEachCaseIsReportedAsItFinishes() async {
        let text = "The backup runs every night."
        let dutch = "De back-up draait elke nacht."
        let detector = MappedDetector(answers: [text: .en, dutch: .nl])
        final class Finished: @unchecked Sendable { var ids: [String] = [] }
        let finished = Finished()
        let run = await runner(.claude, detector: detector, engine: ScriptedEngine(.success(dutch)))
            .run([EvalCase(id: "x", lang: .en, text: text, ref: text)]) { output, raw in
                finished.ids.append(output.id)
                #expect(raw?.output == dutch)
            }
        #expect(run.discarded == ["x": .languageChanged])
        #expect(run.outputs.map(\.output) == [text])
        #expect(run.raw.map(\.output) == [dutch])
        #expect(finished.ids == ["x"])
    }

    @Test func claudeModeSendsEachCaseAsTheTypingRequestAndKeepsTheRawAnswer() async throws {
        let first = "Ik heb de fix nagekeken en het wordt morgen uitgerold."
        let second = "Nous avons livré la version hier soir."
        func reply(_ text: String) -> StubTransport.Reply {
            .response(status: 200, body: Data(#"{"content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20}}"#.utf8))
        }
        let stub = StubTransport([reply(first), reply(second)])
        let price = try #require(ModelPrice.forModel("claude-haiku-5-5"))
        let tracking = CostTrackingTransport(inner: stub, price: price, maxCost: 1, usageLog: nil)
        let engine = ClaudeEngine(model: "claude-haiku-5-5", apiKey: { "sk-test" }, transport: tracking, options: .typing)
        let cases = [
            EvalCase(id: "a", lang: .nl, text: "Ik heb de fix nagekeken en het word morgen uitgerold.", ref: first),
            EvalCase(id: "b", lang: .fr, text: "Nous avons livre la version hier soir.", ref: second),
        ]
        let run = await EvalRunner(
            mode: .claude, guardOn: false, detector: MappedDetector(answers: [:]), engine: engine,
            spelling: ScriptedSpelling(flags: []), oracle: NoFacts(), confirmer: Approves()
        ).run(cases)
        #expect(run.outputs.map(\.output) == [first, second])
        #expect(run.raw.map(\.output) == [first, second])
        let sent = await stub.requests
        #expect(sent.count == 2)
        for (request, item) in zip(sent, cases) {
            let httpBody = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? NSDictionary)
            let messages = try #require(body["messages"] as? [NSDictionary])
            #expect(messages[0]["content"] as? String == item.text)
            #expect(body["thinking"] as? NSDictionary == ["type": "disabled"])
            #expect(body["fallbacks"] == nil)
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        }
    }
}

struct EvalRunnerSystemTests {
    @Test("The spelling path fixes a misspelling with the system's spell checker and word facts", .tags(.requiresSystem))
    func spellingEndToEnd() async {
        let text = "I recieved your invoice yesterday, thanks for the quick turnaround."
        let ref = "I received your invoice yesterday, thanks for the quick turnaround."
        let run = await EvalRunner(mode: .spelling, guardOn: true).run([EvalCase(id: "x", lang: .en, text: text, ref: ref)])
        #expect(run.outputs.map(\.output) == [ref])
        #expect(run.languageMisses.isEmpty)
        #expect(run.outputs.allSatisfy { $0.ms > 0 })
    }
}
