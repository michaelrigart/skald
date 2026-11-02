public enum TypingRoute: Equatable, Sendable {
    case model, spellingOnly(UnavailableReason), off
}

public enum PanelRoute: Equatable, Sendable {
    case use(EngineKind)
    case unavailable(EngineKind, UnavailableReason, alternatives: [EngineKind])
}

public struct EngineRouter: Sendable {
    private let settings: Settings
    private let appleAvailability: UnavailableReason?
    private let thermalPaused: Bool
    private let claudeKeyPresent: Bool

    public init(settings: Settings, appleAvailability: UnavailableReason?, thermalPaused: Bool, claudeKeyPresent: Bool) {
        self.settings = settings
        self.appleAvailability = appleAvailability
        self.thermalPaused = thermalPaused
        self.claudeKeyPresent = claudeKeyPresent
    }

    public func typing(_ language: Language) -> TypingRoute {
        if settings.typingChecks[language] == false { return .off }
        if let appleAvailability { return .spellingOnly(appleAvailability) }
        if thermalPaused { return .spellingOnly(.thermalPause) }
        if settings.modelChecks[language] == false { return .spellingOnly(.languageOff) }
        return .model
    }

    public func panel(requested: EngineKind?) -> PanelRoute {
        let engine = requested ?? settings.panelDefaultEngine
        guard let reason = unavailableReason(engine) else { return .use(engine) }
        return .unavailable(engine, reason, alternatives: EngineKind.allCases.filter { $0 != engine && unavailableReason($0) == nil })
    }

    public var pickerEngines: [EngineKind] {
        [.thisMac] + (settings.studio.isConfigured ? [.macStudio] : []) + [.claude]
    }

    private func unavailableReason(_ engine: EngineKind) -> UnavailableReason? {
        switch engine {
        case .thisMac: appleAvailability
        case .macStudio: settings.studio.isConfigured ? nil : .studioNotConfigured
        case .claude: claudeKeyPresent ? nil : .claudeKeyMissing
        }
    }
}
