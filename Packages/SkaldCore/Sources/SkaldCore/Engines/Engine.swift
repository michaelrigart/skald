public enum EngineAction: String, Codable, CaseIterable, Sendable {
    case check, fix, clearer, shorter, moreFormal, friendlier, confirm
}

public struct EngineRequest: Sendable {
    public var action: EngineAction
    public var language: Language
    public var text: String
    public var confirmOriginal: String?
    public var confirmReplacement: String?

    public init(
        action: EngineAction,
        language: Language,
        text: String,
        confirmOriginal: String? = nil,
        confirmReplacement: String? = nil
    ) {
        self.action = action
        self.language = language
        self.text = text
        self.confirmOriginal = confirmOriginal
        self.confirmReplacement = confirmReplacement
    }
}

public enum UnavailableReason: String, Equatable, Sendable {
    case appleIntelligenceOff, deviceNotEligible, modelNotReady, thermalPause, languageOff
    case studioNotConfigured, studioUnreachable, claudeKeyMissing
}

public enum EngineFailure: Error, Equatable, Sendable {
    case unavailable(UnavailableReason)
    case refused, timedOut, cancelled, truncated, failed
}

public protocol Engine: Sendable {
    var kind: EngineKind { get }
    func run(_ r: EngineRequest) async throws(EngineFailure) -> String
}
