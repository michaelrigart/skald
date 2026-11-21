import SkaldCore
import Synchronization

/// One line per typing request to Claude: a running count and the outcome, never text, a key or an app.
nonisolated final class ClaudeTypingLog: Sendable {
    private let requests = Mutex(0)

    @discardableResult
    func record(_ outcome: Result<String, EngineFailure>) -> Int {
        let count = requests.withLock { value in
            value += 1
            return value
        }
        Log.claude.notice("\(Self.line(count, outcome), privacy: .public)")
        return count
    }

    static func line(_ count: Int, _ outcome: Result<String, EngineFailure>) -> String {
        switch outcome {
        case .success:
            "typing request \(count): answered"
        case .failure(let failure):
            "typing request \(count): \(ClaudeTrouble(failure)?.rawValue ?? "cancelled")"
        }
    }
}

nonisolated struct LoggedEngine: Engine {
    private let inner: any Engine
    private let log: ClaudeTypingLog

    init(_ inner: any Engine, log: ClaudeTypingLog) {
        self.inner = inner
        self.log = log
    }

    var kind: EngineKind { inner.kind }

    func run(_ r: EngineRequest) async throws(EngineFailure) -> String {
        do {
            let answer = try await inner.run(r)
            log.record(.success(answer))
            return answer
        } catch {
            log.record(.failure(error))
            throw error
        }
    }
}
