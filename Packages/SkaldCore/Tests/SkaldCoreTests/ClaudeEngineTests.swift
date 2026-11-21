import Foundation
import Testing
@testable import SkaldCore

struct ClaudeEngineTests {
    private static let request = EngineRequest(action: .shorter, language: .fr, text: "Bonjour tout le monde, comment allez-vous aujourd'hui ?")

    private func engine(_ transport: StubTransport, key: String? = "sk-test-key") -> ClaudeEngine {
        ClaudeEngine(model: "claude-opus-5-5", apiKey: { key }, transport: transport)
    }

    private func reply(stop: String = "end_turn", content: String) -> String {
        #"{"id":"msg_1","type":"message","role":"assistant","content":\#(content),"stop_reason":"\#(stop)"}"#
    }

    private func failure(_ engine: ClaudeEngine) async -> EngineFailure? {
        do {
            _ = try await engine.run(Self.request)
            return nil
        } catch {
            return error
        }
    }

    @Test("sends the exact URL, method, headers and body for a shorter/fr request; a wrong header or an extra field is rejected by the API")
    func requestShape() async throws {
        let transport = StubTransport(json: reply(content: #"[{"type":"text","text":"Bonjour à tous."}]"#))
        let text = try await engine(transport).run(Self.request)
        #expect(text == "Bonjour à tous.")

        let sent = try #require(await transport.requests.first)
        #expect(await transport.requests.count == 1)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.httpMethod == "POST")
        #expect(sent.allHTTPHeaderFields == [
            "x-api-key": "sk-test-key",
            "anthropic-version": "2026-10-21",
            "anthropic-beta": "server-side-fallback-2026-07-01",
            "Content-Type": "application/json",
        ])

        let body = try #require(sent.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
        let expected: NSDictionary = [
            "model": "claude-opus-5-5",
            "max_tokens": 4096,
            "fallbacks": "default",
            "system": Prompts.instructions(.shorter, .fr),
            "messages": [["role": "user", "content": Prompts.prompt(Self.request)]],
            "output_config": ["effort": "low"],
        ]
        #expect(decoded == expected)
    }

    @Test("joins every text block and ignores other block types; thinking blocks would otherwise leak into the answer")
    func joinsTextBlocks() async throws {
        let content = #"[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Bonjour "},{"type":"tool_use","id":"x"},{"type":"text","text":"à tous."}]"#
        let text = try await engine(StubTransport(json: reply(content: content))).run(Self.request)
        #expect(text == "Bonjour à tous.")
    }

    @Test("cleans a wrapped reply so a quoted answer is not offered with its quotes")
    func cleansReply() async throws {
        let transport = StubTransport(json: reply(content: #"[{"type":"text","text":"\"Bonjour à tous.\""}]"#))
        #expect(try await engine(transport).run(Self.request) == "Bonjour à tous.")
    }

    @Test("a reply that is empty once cleaned is failed, not an empty success", arguments: ["  \\n", "\\\"\\\"", "<think></think>"])
    func emptyAfterCleaning(text: String) async {
        let transport = StubTransport(json: reply(content: #"[{"type":"text","text":"\#(text)"}]"#))
        #expect(await failure(engine(transport)) == .failed)
    }

    @Test("a refusal stop reason is refused even when text is present")
    func refusal() async {
        let transport = StubTransport(json: reply(stop: "refusal", content: #"[{"type":"text","text":"I can't"}]"#))
        #expect(await failure(engine(transport)) == .refused)
    }

    @Test("a max_tokens stop reason is truncated, so a cut-off rewrite is never applied")
    func truncation() async {
        let transport = StubTransport(json: reply(stop: "max_tokens", content: #"[{"type":"text","text":"Bonjour"}]"#))
        #expect(await failure(engine(transport)) == .truncated)
    }

    @Test("a 200 with no text block, or with undecodable JSON, is failed")
    func unusableBodies() async {
        #expect(await failure(engine(StubTransport(json: reply(content: "[]")))) == .failed)
        #expect(await failure(engine(StubTransport(json: reply(content: #"[{"type":"thinking","thinking":"x"}]"#)))) == .failed)
        #expect(await failure(engine(StubTransport(json: "not json"))) == .failed)
    }

    @Test("a non-2xx status is failed", arguments: [400, 401, 429, 500, 529])
    func httpErrors(status: Int) async {
        let transport = StubTransport(status: status, json: #"{"type":"error","error":{"type":"x","message":"y"}}"#)
        #expect(await failure(engine(transport)) == .failed)
    }

    @Test("transport errors map to timedOut, cancelled or failed")
    func transportErrors() async {
        #expect(await failure(engine(StubTransport(failure: URLError(.timedOut)))) == .timedOut)
        #expect(await failure(engine(StubTransport(failure: URLError(.cancelled)))) == .cancelled)
        #expect(await failure(engine(StubTransport(failure: CancellationError()))) == .cancelled)
        #expect(await failure(engine(StubTransport(failure: URLError(.cannotConnectToHost)))) == .failed)
        #expect(await failure(engine(StubTransport(failure: URLError(.notConnectedToInternet)))) == .failed)
    }

    @Test("a nil or empty key is unavailable and sends nothing", arguments: [nil, ""])
    func missingKey(key: String?) async {
        let transport = StubTransport(json: reply(content: #"[{"type":"text","text":"x"}]"#))
        #expect(await failure(engine(transport, key: key)) == .unavailable(.claudeKeyMissing))
        #expect(await transport.requests.isEmpty)
    }

    @Test("the key is read for each request, so a key saved later is used without rebuilding the engine")
    func keyReadPerRequest() async throws {
        let box = KeyBox()
        let transport = StubTransport(json: reply(content: #"[{"type":"text","text":"Bonjour."}]"#))
        let engine = ClaudeEngine(model: "m", apiKey: { box.key }, transport: transport)
        do {
            _ = try await engine.run(Self.request)
            Issue.record("expected the missing key to fail")
        } catch {
            #expect(error == .unavailable(.claudeKeyMissing))
        }
        box.key = "sk-later"
        _ = try await engine.run(Self.request)
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "x-api-key") == "sk-later")
    }

    @Test("the engine reports the Claude kind")
    func kind() {
        #expect(engine(StubTransport([])).kind == .claude)
    }
}

private final class KeyBox: @unchecked Sendable { // reason: test-only mutable holder, written before the engine runs again, never concurrently
    var key: String?
}
