import Foundation
import SkaldCore
import SkaldCoreTestSupport
import Testing
@testable import SkaldPlatform27

private let haiku = ModelPrice.forModel("claude-haiku-5-5")!

private func usageReply(input: Int = 1_000, output: Int = 200) -> StubTransport.Reply {
    .response(status: 200, body: Data(#"{"content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}"#.utf8))
}

private func request(bytes: Int = 100) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.invalid/v1/messages")!)
    request.httpMethod = "POST"
    request.httpBody = Data(repeating: 0x20, count: bytes)
    return request
}

private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "skald-eval-\(UUID().uuidString)-\(name)")
}

private func emptyFile(_ name: String) -> URL {
    let url = temporaryFile(name)
    FileManager.default.createFile(atPath: url.path, contents: Data())
    return url
}

private func lines(of url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

private let claudeOptions = EvalOptions(set: "s.jsonl", mode: .claude, guardOn: true, out: nil, claudeModel: "claude-haiku-5-5", maxCost: 1)

struct EvalClaudeTests {
    @Test func pricesAreExactModelIDs() {
        #expect(ModelPrice.forModel("claude-haiku-5-5") == ModelPrice(inputPerMTok: 0.10, outputPerMTok: 0.50))
        #expect(ModelPrice.forModel("claude-sonnet-5-5") == ModelPrice(inputPerMTok: 2, outputPerMTok: 10))
        #expect(ModelPrice.forModel("claude-opus-5-5") == ModelPrice(inputPerMTok: 4, outputPerMTok: 20))
        for id in ["claude-haiku-4-5", "claude-haiku-5-5-20260101", "haiku", ""] { #expect(ModelPrice.forModel(id) == nil) }
        #expect(abs(ModelPrice.forModel("claude-haiku-5-5")!.cost(input: 1_000, output: 200) - 0.0002) < 1e-12)
    }

    @Test func costTrackingRecordsEachRequestAndSums() async throws {
        let log = emptyFile("usage.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let transport = CostTrackingTransport(inner: StubTransport([usageReply(), usageReply()]), price: haiku, maxCost: 1, usageLog: log)
        _ = try await transport.send(request())
        _ = try await transport.send(request())
        #expect(await transport.summary == "claude usage: 2 requests, 2000 input tokens, 400 output tokens, $0.0004 of $1.00; $0.000200 a check, $3.00 a month at 500 checks a day")
        #expect(try lines(of: log) == [
            #"{"input_tokens":1000,"output_tokens":200,"cost":0.000200,"total_cost":0.000200}"#,
            #"{"input_tokens":1000,"output_tokens":200,"cost":0.000200,"total_cost":0.000400}"#,
        ])
    }

    @Test func aRequestWhoseCeilingWouldPassTheLimitIsNeverSent() async throws {
        let stub = StubTransport([usageReply(input: 1_000, output: 2_000), usageReply()])
        let transport = CostTrackingTransport(inner: stub, price: haiku, maxCost: 0.003, usageLog: nil)
        _ = try await transport.send(request(bytes: 1_000))
        await #expect(throws: BudgetExceeded.self) { try await transport.send(request(bytes: 1_000)) }
        #expect(await stub.requests.count == 1)
        #expect(await transport.summary.hasSuffix(", stopped at the cost limit"))
    }

    @Test func aLostAnswerIsChargedItsCeiling() async throws {
        let stub = StubTransport([.failure(URLError(.timedOut)), usageReply()])
        let transport = CostTrackingTransport(inner: stub, price: haiku, maxCost: 0.004, usageLog: nil)
        await #expect(throws: URLError.self) { try await transport.send(request(bytes: 1_000)) }
        #expect(abs(await transport.spent - 0.002148) < 1e-12)
        await #expect(throws: BudgetExceeded.self) { try await transport.send(request(bytes: 1_000)) }
        #expect(await stub.requests.count == 1)
        #expect(await transport.summary == "claude usage: 1 requests, 0 input tokens, 0 output tokens, $0.0021 of $0.00; $0.002148 a check, $32.22 a month at 500 checks a day, stopped at the cost limit")
    }

    @Test("an answer without usage, whether a 200, a 5xx or a lost one, is charged its ceiling and logged with null tokens", arguments: [
        StubTransport.Reply.response(status: 200, body: Data(#"{"content":[{"type":"text","text":"x"}]}"#.utf8)),
        .response(status: 529, body: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"y"}}"#.utf8)),
        .failure(URLError(.timedOut)),
    ])
    func anAnswerWithoutUsageIsChargedItsCeiling(_ reply: StubTransport.Reply) async throws {
        let log = emptyFile("usage.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let transport = CostTrackingTransport(inner: StubTransport([reply]), price: haiku, maxCost: 1, usageLog: log)
        _ = try? await transport.send(request(bytes: 1_000))
        #expect(abs(await transport.spent - 0.002148) < 1e-12)
        #expect(try lines(of: log) == [#"{"input_tokens":null,"output_tokens":null,"cost":0.002148,"total_cost":0.002148}"#])
        #expect(await transport.logFailure == nil)
    }

    @Test func aUsageLogThatCannotBeWrittenStopsTheNextRequest() async throws {
        let missing = temporaryFile("missing/usage.jsonl")
        let stub = StubTransport([usageReply(), usageReply()])
        let transport = CostTrackingTransport(inner: stub, price: haiku, maxCost: 1, usageLog: missing)
        _ = try await transport.send(request())
        #expect(await transport.logFailure?.hasPrefix("cannot write \(missing.path)") == true)
        await #expect(throws: UsageLogUnwritable.self) { try await transport.send(request()) }
        #expect(await stub.requests.count == 1)
    }

    @Test func aRunWhoseOutputDirectoryIsMissingSendsNothing() async throws {
        let missing = temporaryFile("missing/out.jsonl")
        let stub = StubTransport([usageReply()])
        var options = claudeOptions
        options.out = missing.path
        #expect(throws: EvalUsageError.self) {
            try EvalClaudeSession.open(options, environment: ["SKALD_EVAL_CLAUDE_KEY": "sk-test"], transport: stub)
        }
        #expect(await stub.requests.isEmpty)
    }

    @Test func aMissingKeyCreatesNoFile() throws {
        let out = temporaryFile("out.jsonl")
        var options = claudeOptions
        options.out = out.path
        #expect(throws: EvalUsageError(message: "set SKALD_EVAL_CLAUDE_KEY to a Claude API key")) {
            try EvalClaudeSession.open(options, environment: [:], transport: StubTransport([]))
        }
        for path in [out.path, out.path + ".raw.jsonl", out.path + ".usage.jsonl"] { #expect(!FileManager.default.fileExists(atPath: path)) }
    }

    @Test("a run never overwrites an earlier run's record, and creates nothing when any of the three files exists", arguments: ["", ".raw.jsonl", ".usage.jsonl"])
    func anEarlierRunIsNeverOverwritten(_ suffix: String) throws {
        let out = temporaryFile("out.jsonl")
        let existing = URL(filePath: out.path + suffix)
        try "paid answer\n".write(to: existing, atomically: true, encoding: .utf8)
        defer { for path in [out.path, out.path + ".raw.jsonl", out.path + ".usage.jsonl"] { try? FileManager.default.removeItem(atPath: path) } }
        var options = claudeOptions
        options.out = out.path
        #expect(throws: EvalUsageError(message: "\(existing.path) already exists; a claude run never overwrites an earlier run's answers")) {
            try EvalClaudeSession.open(options, environment: ["SKALD_EVAL_CLAUDE_KEY": "sk-test"], transport: StubTransport([]))
        }
        #expect(try lines(of: existing) == ["paid answer"])
        for other in ["", ".raw.jsonl", ".usage.jsonl"] where other != suffix { #expect(!FileManager.default.fileExists(atPath: out.path + other)) }
    }

    @Test func aRunKeepsEachCasesAnswerAsItFinishes() async throws {
        let out = temporaryFile("out.jsonl")
        defer { for path in [out.path, out.path + ".raw.jsonl", out.path + ".usage.jsonl"] { try? FileManager.default.removeItem(atPath: path) } }
        var options = claudeOptions
        options.out = out.path
        let stub = StubTransport([usageReply()])
        let session = try EvalClaudeSession.open(options, environment: ["SKALD_EVAL_CLAUDE_KEY": "sk-test"], transport: stub)
        for suffix in ["", ".raw.jsonl", ".usage.jsonl"] { #expect(FileManager.default.fileExists(atPath: out.path + suffix)) }
        let first = EvalOutput(id: "a", lang: .nl, output: "x", error: nil, ms: 1)
        try await session.files.append(first, raw: first)
        #expect(try lines(of: out).count == 1)
        #expect(try lines(of: URL(filePath: out.path + ".raw.jsonl")).count == 1)
        _ = try await session.tracker.send(request())
        #expect(try lines(of: URL(filePath: out.path + ".usage.jsonl")).count == 1)
    }

    @Test func theKeyComesOnlyFromSkaldEvalClaudeKey() throws {
        #expect(try EvalClaudeKey.read(from: ["SKALD_EVAL_CLAUDE_KEY": "sk-eval"]) == "sk-eval")
        for environment in [[:], ["SKALD_EVAL_CLAUDE_KEY": ""], ["ANTHROPIC_API_KEY": "sk-other"]] {
            #expect(throws: EvalUsageError(message: "set SKALD_EVAL_CLAUDE_KEY to a Claude API key")) { try EvalClaudeKey.read(from: environment) }
        }
    }

    @Test func replayReadsTheProxyFormatByID() throws {
        let file = temporaryFile("replay.jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [#"{"id":"a","lang":"nl","ms":0,"output":"x"}"#, #"{"id":"b","lang":"fr","ms":0,"output":null}"#, ""]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(try EvalReplay.load(file) == ["a": "x"])
    }
}
