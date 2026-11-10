import Foundation

public struct ClaudeEngine: Engine {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let model: String
    private let apiKey: @Sendable () -> String?
    private let transport: any HTTPTransport

    public var kind: EngineKind { .claude }

    public init(model: String, apiKey: @escaping @Sendable () -> String?, transport: any HTTPTransport) {
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    public func run(_ r: EngineRequest) async throws(EngineFailure) -> String {
        guard let key = apiKey(), !key.isEmpty else { throw .unavailable(.claudeKeyMissing) }
        let body = Body(
            model: model,
            system: Prompts.instructions(r.action, r.language),
            messages: [Message(role: "user", content: Prompts.prompt(r))]
        )
        let request = try URLRequest.post(Self.endpoint, json: body, headers: [
            "x-api-key": key,
            "anthropic-version": "2026-10-21",
            "anthropic-beta": "server-side-fallback-2026-07-01",
            "content-type": "application/json",
        ])
        let data = try await transport.body(of: request) { error in
            if error.isCancellation { return .cancelled }
            if (error as? URLError)?.code == .timedOut { return .timedOut }
            return .failed
        }
        return try Self.answer(from: data, input: r.text)
    }

    private static func answer(from data: Data, input: String) throws(EngineFailure) -> String {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw .failed }
        switch reply.stopReason {
        case "refusal": throw .refused
        case "max_tokens": throw .truncated
        default: break
        }
        let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        let cleaned = OutputCleaner.clean(text, input: input)
        guard !cleaned.isEmpty else { throw .failed }
        return cleaned
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Body: Encodable {
        struct OutputConfig: Encodable {
            let effort = "low"
        }

        let model: String
        let maxTokens = 4096
        let fallbacks = "default"
        let system: String
        let messages: [Message]
        let outputConfig = OutputConfig()

        private enum CodingKeys: String, CodingKey {
            case model, system, messages, fallbacks
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
        let stopReason: String?

        private enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }
}
