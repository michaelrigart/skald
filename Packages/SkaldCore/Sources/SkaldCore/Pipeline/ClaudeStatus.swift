public struct ClaudeStatus: Equatable, Sendable {
    /// The focused field's checks go to Claude now.
    public var sending: Bool
    /// From a failed request until the next success.
    public var trouble: ClaudeTrouble?

    public init(sending: Bool, trouble: ClaudeTrouble?) {
        self.sending = sending
        self.trouble = trouble
    }

    public static let quiet = ClaudeStatus(sending: false, trouble: nil)
}
