public struct ClaudeStatus: Equatable, Sendable {
    /// The focused field's checks go to Claude now.
    public var sending: Bool
    /// From a failed request until the next success.
    public var trouble: ClaudeTrouble?
    /// Failures have paused Claude's requests, so checks go to the on-device route until the pause ends.
    public var suspended: Bool

    public init(sending: Bool, trouble: ClaudeTrouble?, suspended: Bool = false) {
        self.sending = sending
        self.trouble = trouble
        self.suspended = suspended
    }

    public static let quiet = ClaudeStatus(sending: false, trouble: nil)
}

/// How a typing request that was sent ended. A request that never left, such as one without a key, has none.
public enum ClaudeOutcome: Equatable, Sendable {
    case answered, failed(ClaudeTrouble), cancelled

    init?(_ result: Result<String, EngineFailure>) {
        switch result {
        case .success: self = .answered
        case .failure(.unavailable(.claudeKeyMissing)): return nil
        case .failure(let failure): self = ClaudeTrouble(failure).map(Self.failed) ?? .cancelled
        }
    }
}
