import SkaldCore
import Synchronization

/// One line per typing request sent to Claude: a running count and the outcome, never text, a key or an app.
nonisolated final class ClaudeTypingLog: Sendable {
    private let requests = Mutex(0)

    @discardableResult
    func record(_ outcome: ClaudeOutcome) -> Int {
        let count = requests.withLock { value in
            value += 1
            return value
        }
        Log.claude.notice("\(Self.line(count, outcome), privacy: .public)")
        return count
    }

    static func line(_ count: Int, _ outcome: ClaudeOutcome) -> String {
        switch outcome {
        case .answered: "typing request \(count): answered"
        case .failed(let trouble): "typing request \(count): \(trouble.rawValue)"
        case .cancelled: "typing request \(count): cancelled"
        }
    }
}
