import Foundation

public struct StudioEngine: Engine {
    private static let unreachable: Set<URLError.Code> = [
        .cannotConnectToHost, .notConnectedToInternet, .timedOut, .cannotFindHost,
    ]

    private let endpoint: StudioEndpoint
    private let transport: any HTTPTransport

    public var kind: EngineKind { .macStudio }

    public init(endpoint: StudioEndpoint, transport: any HTTPTransport) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public func run(_ r: EngineRequest) async throws(EngineFailure) -> String {
        guard endpoint.isConfigured else { throw .unavailable(.studioNotConfigured) }
        let messages = [
            Message(role: "system", content: Prompts.instructions(r.action, r.language)),
            Message(role: "user", content: Prompts.prompt(r)),
        ]
        let request: URLRequest
        switch endpoint.api {
        case .ollama:
            request = try post("api/chat", OllamaBody(model: endpoint.model, messages: messages))
        case .openAICompatible:
            request = try post("v1/chat/completions", OpenAIBody(model: endpoint.model, messages: messages))
        }
        let data = try await transport.body(of: request) { error in
            if error.isCancellation { return .cancelled }
            if let code = (error as? URLError)?.code, Self.unreachable.contains(code) { return .unavailable(.studioUnreachable) }
            return .failed
        }
        let text: String? = switch endpoint.api {
        case .ollama: (try? JSONDecoder().decode(OllamaReply.self, from: data))?.message.content
        case .openAICompatible: (try? JSONDecoder().decode(OpenAIReply.self, from: data))?.choices.first?.message.content
        }
        guard let text, !text.isEmpty else { throw .failed }
        return OutputCleaner.clean(text, input: r.text)
    }

    private func post(_ path: String, _ body: some Encodable) throws(EngineFailure) -> URLRequest {
        var base = endpoint.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/\(path)") else { throw .unavailable(.studioNotConfigured) }
        return try URLRequest.post(url, json: body, headers: ["content-type": "application/json"])
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct ReplyMessage: Decodable {
        let content: String
    }

    private struct OllamaBody: Encodable {
        struct Options: Encodable {
            let numPredict = 2048

            private enum CodingKeys: String, CodingKey {
                case numPredict = "num_predict"
            }
        }

        let model: String
        let messages: [Message]
        let stream = false
        let think = false
        let keepAlive = "10m"
        let options = Options()

        private enum CodingKeys: String, CodingKey {
            case model, messages, stream, think, options
            case keepAlive = "keep_alive"
        }
    }

    private struct OpenAIBody: Encodable {
        let model: String
        let messages: [Message]
        let maxTokens = 2048

        private enum CodingKeys: String, CodingKey {
            case model, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct OllamaReply: Decodable {
        let message: ReplyMessage
    }

    private struct OpenAIReply: Decodable {
        struct Choice: Decodable {
            let message: ReplyMessage
        }

        let choices: [Choice]
    }
}
