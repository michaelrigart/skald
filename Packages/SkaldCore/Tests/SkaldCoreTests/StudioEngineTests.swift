import Foundation
import Testing
@testable import SkaldCore

struct StudioEngineTests {
    private static let request = EngineRequest(action: .fix, language: .nl, text: "Ik heb het gedownload.")

    private func engine(
        _ transport: StubTransport,
        api: StudioEndpoint.API = .ollama,
        baseURL: String = "http://studio.local:11434",
        model: String = "qwen3:14b"
    ) -> StudioEngine {
        StudioEngine(endpoint: StudioEndpoint(api: api, baseURL: baseURL, model: model), transport: transport)
    }

    private func failure(_ engine: StudioEngine) async -> EngineFailure? {
        do {
            _ = try await engine.run(Self.request)
            return nil
        } catch {
            return error
        }
    }

    private func messages() -> [[String: String]] {
        [
            ["role": "system", "content": Prompts.instructions(.fix, .nl)],
            ["role": "user", "content": Prompts.prompt(Self.request)],
        ]
    }

    private func jsonBody(_ request: URLRequest) throws -> NSDictionary {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test("Ollama: posts to /api/chat with the exact body and reads message.content")
    func ollama() async throws {
        let transport = StubTransport(json: #"{"model":"qwen3:14b","message":{"role":"assistant","content":"Ik heb het gedownload."},"done":true}"#)
        let text = try await engine(transport).run(Self.request)
        #expect(text == "Ik heb het gedownload.")

        let sent = try #require(await transport.requests.first)
        #expect(sent.url?.absoluteString == "http://studio.local:11434/api/chat")
        #expect(sent.httpMethod == "POST")
        #expect(sent.allHTTPHeaderFields == ["Content-Type": "application/json"])
        let expected: NSDictionary = [
            "model": "qwen3:14b",
            "stream": false,
            "think": false,
            "keep_alive": "10m",
            "options": ["num_predict": 2048],
            "messages": messages(),
        ]
        #expect(try jsonBody(sent) == expected)
    }

    @Test("OpenAI-compatible: posts to /v1/chat/completions with the exact body and reads choices[0].message.content")
    func openAI() async throws {
        let transport = StubTransport(json: #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Ik heb het gedownload."}}]}"#)
        let text = try await engine(transport, api: .openAICompatible, baseURL: "http://studio.local:1234").run(Self.request)
        #expect(text == "Ik heb het gedownload.")

        let sent = try #require(await transport.requests.first)
        #expect(sent.url?.absoluteString == "http://studio.local:1234/v1/chat/completions")
        #expect(sent.httpMethod == "POST")
        let expected: NSDictionary = ["model": "qwen3:14b", "max_tokens": 2048, "messages": messages()]
        #expect(try jsonBody(sent) == expected)
    }

    @Test("the base URL and path are joined with exactly one slash, with or without a trailing slash", arguments: [
        ("http://studio.local:11434", "http://studio.local:11434/api/chat"),
        ("http://studio.local:11434/", "http://studio.local:11434/api/chat"),
        ("http://studio.local:11434//", "http://studio.local:11434/api/chat"),
        ("https://studio.local/proxy/", "https://studio.local/proxy/api/chat"),
    ])
    func urlJoining(base: String, expected: String) async throws {
        let transport = StubTransport(json: #"{"message":{"content":"x"}}"#)
        _ = try await engine(transport, baseURL: base).run(Self.request)
        #expect(await transport.requests.first?.url?.absoluteString == expected)
    }

    @Test("the OpenAI-compatible path also joins with one slash")
    func openAIUrlJoining() async throws {
        let transport = StubTransport(json: #"{"choices":[{"message":{"content":"x"}}]}"#)
        _ = try await engine(transport, api: .openAICompatible, baseURL: "http://studio.local:1234/").run(Self.request)
        #expect(await transport.requests.first?.url?.absoluteString == "http://studio.local:1234/v1/chat/completions")
    }

    @Test("cleans a wrapped reply, such as an empty think block before the answer")
    func cleansReply() async throws {
        let transport = StubTransport(json: #"{"message":{"content":"<think></think>\nIk heb het gedownload."}}"#)
        #expect(try await engine(transport).run(Self.request) == "Ik heb het gedownload.")
    }

    @Test("a reply that is empty once cleaned is failed, not an empty success", arguments: ["  \\n", "\\\"\\\"", "<think></think>"])
    func emptyAfterCleaning(text: String) async {
        let ollama = StubTransport(json: #"{"message":{"content":"\#(text)"},"done":true}"#)
        #expect(await failure(engine(ollama)) == .failed)
        let openAI = StubTransport(json: #"{"choices":[{"message":{"content":"\#(text)"}}]}"#)
        #expect(await failure(engine(openAI, api: .openAICompatible)) == .failed)
    }

    @Test("Ollama done_reason length is truncated, so a cut-off rewrite is never applied")
    func ollamaTruncation() async {
        let transport = StubTransport(json: #"{"message":{"content":"Ik heb"},"done":true,"done_reason":"length"}"#)
        #expect(await failure(engine(transport)) == .truncated)
    }

    @Test("OpenAI-compatible finish_reason length is truncated, so a cut-off rewrite is never applied")
    func openAITruncation() async {
        let transport = StubTransport(json: #"{"choices":[{"message":{"content":"Ik heb"},"finish_reason":"length"}]}"#)
        #expect(await failure(engine(transport, api: .openAICompatible)) == .truncated)
    }

    @Test("a normal stop reason is not truncated")
    func normalStop() async throws {
        let transport = StubTransport(json: #"{"message":{"content":"Ik heb."},"done":true,"done_reason":"stop"}"#)
        #expect(try await engine(transport).run(Self.request) == "Ik heb.")
    }

    @Test("connection errors are unreachable", arguments: [
        URLError.cannotConnectToHost, .notConnectedToInternet, .timedOut, .cannotFindHost,
    ])
    func unreachable(code: URLError.Code) async {
        #expect(await failure(engine(StubTransport(failure: URLError(code)))) == .unavailable(.studioUnreachable))
    }

    @Test("cancellation is cancelled, not unreachable, so a superseded request does not blame the Studio")
    func cancellation() async {
        #expect(await failure(engine(StubTransport(failure: URLError(.cancelled)))) == .cancelled)
        #expect(await failure(engine(StubTransport(failure: CancellationError()))) == .cancelled)
    }

    @Test("other transport errors are failed")
    func otherErrors() async {
        #expect(await failure(engine(StubTransport(failure: URLError(.badServerResponse)))) == .failed)
    }

    @Test("a non-2xx status is failed", arguments: [400, 404, 500, 503])
    func httpErrors(status: Int) async {
        #expect(await failure(engine(StubTransport(status: status, json: #"{"error":"x"}"#))) == .failed)
    }

    @Test("a missing or empty reply, or undecodable JSON, is failed for both APIs")
    func unusableBodies() async {
        #expect(await failure(engine(StubTransport(json: #"{"done":true}"#))) == .failed)
        #expect(await failure(engine(StubTransport(json: #"{"message":{"content":""}}"#))) == .failed)
        #expect(await failure(engine(StubTransport(json: "nope"))) == .failed)
        #expect(await failure(engine(StubTransport(json: #"{"choices":[]}"#), api: .openAICompatible)) == .failed)
    }

    @Test("an unconfigured endpoint is unavailable and sends nothing", arguments: [
        ("", "qwen3:14b"), ("studio.local", "qwen3:14b"), ("http://studio.local:11434", ""),
    ])
    func unconfigured(base: String, model: String) async {
        let transport = StubTransport(json: #"{"message":{"content":"x"}}"#)
        #expect(await failure(engine(transport, baseURL: base, model: model)) == .unavailable(.studioNotConfigured))
        #expect(await transport.requests.isEmpty)
    }

    @Test("the engine reports the Mac Studio kind")
    func kind() {
        #expect(engine(StubTransport([])).kind == .macStudio)
    }
}
