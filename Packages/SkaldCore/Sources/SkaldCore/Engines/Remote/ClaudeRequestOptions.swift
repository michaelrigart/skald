/// What a Claude request asks beyond the model and the text. `.typing` is provisional until the gate run
/// settles it (spec 2026-11-20, "The gate"); this is the one place to change it.
public struct ClaudeRequestOptions: Equatable, Sendable {
    public enum Thinking: Equatable, Sendable { case modelDefault, disabled }

    public var thinking: Thinking
    public var serverFallbacks: Bool

    public init(thinking: Thinking, serverFallbacks: Bool) {
        self.thinking = thinking
        self.serverFallbacks = serverFallbacks
    }

    public static let panel = ClaudeRequestOptions(thinking: .modelDefault, serverFallbacks: true)
    public static let typing = ClaudeRequestOptions(thinking: .disabled, serverFallbacks: false)
}
