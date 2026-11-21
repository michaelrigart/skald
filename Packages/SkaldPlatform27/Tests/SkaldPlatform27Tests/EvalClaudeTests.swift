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

struct EvalClaudeTests {
    @Test func pricesAreExactModelIDs() {
        #expect(ModelPrice.forModel("claude-haiku-5-5") == ModelPrice(inputPerMTok: 0.10, outputPerMTok: 0.50))
        #expect(ModelPrice.forModel("claude-sonnet-5-5") == ModelPrice(inputPerMTok: 2, outputPerMTok: 10))
        #expect(ModelPrice.forModel("claude-opus-5-5") == ModelPrice(inputPerMTok: 4, outputPerMTok: 20))
        for id in ["claude-haiku-4-5", "claude-haiku-5-5-20260101", "haiku", ""] { #expect(ModelPrice.forModel(id) == nil) }
        #expect(abs(ModelPrice.forModel("claude-haiku-5-5")!.cost(input: 1_000, output: 200) - 0.0002) < 1e-12)
    }

    @Test func costTrackingRecordsEachRequestAndSums() async throws {
        let log = temporaryFile("usage.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let transport = CostTrackingTransport(inner: StubTransport([usageReply(), usageReply()]), price: haiku, maxCost: 1, usageLog: log)
        _ = try await transport.send(request())
        _ = try await transport.send(request())
        #expect(await transport.summary == "claude usage: 2 requests, 2000 input tokens, 400 output tokens, $0.0004 of $1.00; $0.000200 a check, $3.00 a month at 500 checks a day")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [
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
