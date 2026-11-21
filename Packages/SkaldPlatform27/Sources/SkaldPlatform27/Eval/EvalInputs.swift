import Foundation

public enum EvalReplay {
    private struct Recorded: Decodable {
        let id: String
        let output: String?
    }

    public static func load(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            let record = try JSONDecoder().decode(Recorded.self, from: Data(line.utf8))
            if let output = record.output { table[record.id] = output }
        }
        return table
    }
}

public enum EvalClaudeKey {
    public static let variable = "SKALD_EVAL_CLAUDE_KEY"

    public static func read(from environment: [String: String]) throws(EvalUsageError) -> String {
        guard let key = environment[variable], !key.isEmpty else { throw EvalUsageError(message: "set \(variable) to a Claude API key") }
        return key
    }
}
