import Foundation
import SkaldCore

public struct ModelPrice: Equatable, Sendable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double

    public static func forModel(_ id: String) -> ModelPrice? {
        switch id {
        case "claude-haiku-5-5": ModelPrice(inputPerMTok: 0.10, outputPerMTok: 0.50)
        case "claude-sonnet-5-5": ModelPrice(inputPerMTok: 2, outputPerMTok: 10)
        case "claude-opus-5-5": ModelPrice(inputPerMTok: 4, outputPerMTok: 20)
        default: nil
        }
    }

    /// The models that answer a request with disabled thinking by a 400.
    public static func requiresThinking(_ id: String) -> Bool {
        id == "claude-sonnet-5-5" || id == "claude-opus-5-5"
    }

    public func cost(input: Int, output: Int) -> Double {
        Double(input) / 1e6 * inputPerMTok + Double(output) / 1e6 * outputPerMTok
    }
}

public struct BudgetExceeded: Error {}

public struct UsageLogUnwritable: Error {
    public let message: String
}

/// Wraps the real transport and keeps `--max-cost` a strict bound: a request is sent only when its ceiling (the body's
/// byte count as input tokens, `ClaudeEngine.maxTokens` as output) fits in what is left, and one whose answer carries
/// no usage is charged that ceiling.
public actor CostTrackingTransport: HTTPTransport {
    private let inner: any HTTPTransport
    private let price: ModelPrice
    private let maxCost: Double
    private let usageLog: URL?
    private var requests = 0, inputTokens = 0, outputTokens = 0
    private var stoppedByBudget = false
    public private(set) var spent = 0.0
    public private(set) var logFailure: String?

    public init(inner: any HTTPTransport, price: ModelPrice, maxCost: Double, usageLog: URL?) {
        self.inner = inner
        self.price = price
        self.maxCost = maxCost
        self.usageLog = usageLog
    }

    public var summary: String {
        let perCheck = requests == 0 ? 0 : spent / Double(requests)
        return String(
            format: "claude usage: %d requests, %d input tokens, %d output tokens, $%.4f of $%.2f; $%.6f a check, $%.2f a month at 500 checks a day%@",
            requests, inputTokens, outputTokens, spent, maxCost, perCheck, perCheck * 500 * 30, stoppedByBudget ? ", stopped at the cost limit" : ""
        )
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let logFailure { throw UsageLogUnwritable(message: logFailure) }
        let ceiling = price.cost(input: request.httpBody?.count ?? 0, output: ClaudeEngine.maxTokens)
        guard spent + ceiling <= maxCost else {
            stoppedByBudget = true
            throw BudgetExceeded()
        }
        spent += ceiling
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await inner.send(request)
        } catch {
            record(nil, ceiling: ceiling)
            throw error
        }
        record(try? JSONDecoder().decode(Reply.self, from: data).usage, ceiling: ceiling)
        return (data, response)
    }

    private func record(_ usage: Reply.Usage?, ceiling: Double) {
        let charge = usage.map { price.cost(input: $0.inputTokens, output: $0.outputTokens) } ?? ceiling
        spent += charge - ceiling
        requests += 1
        inputTokens += usage?.inputTokens ?? 0
        outputTokens += usage?.outputTokens ?? 0
        let tokens = usage.map { "\($0.inputTokens),\"output_tokens\":\($0.outputTokens)" } ?? "null,\"output_tokens\":null"
        let line = String(format: "{\"input_tokens\":%@,\"cost\":%.6f,\"total_cost\":%.6f}\n", tokens, charge, spent)
        FileHandle.standardError.write(Data("claude request: \(line)".utf8))
        if let usageLog { append(Data(line.utf8), to: usageLog) }
    }

    private func append(_ line: Data, to url: URL) {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            logFailure = "cannot write \(url.path): \(error.localizedDescription)"
        }
    }

    private struct Reply: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens", outputTokens = "output_tokens"
            }
        }

        let usage: Usage?
    }
}
