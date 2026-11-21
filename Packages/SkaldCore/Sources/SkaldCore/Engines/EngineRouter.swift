public enum TypingRoute: Equatable, Sendable {
    case model, claude, spellingOnly(UnavailableReason), off
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

    /// `.claude` when the language is Dutch or French, the switch is on, the language is ticked, a key is stored and
    /// the app has a bundle identifier and its mode is `.on`; otherwise the on-device route. Never `.claude` for English.
    public func typing(_ language: Language, app: String) -> TypingRoute {
        let identified = !app.isEmpty && app != FieldID.unknownApp
        return identified && claudeTypingLanguages.contains(language) && settings.mode(app: app) == .on ? .claude : onDevice(language)
    }

    public func onDevice(_ language: Language) -> TypingRoute {
        if settings.typingChecks[language] == false { return .off }
        if let appleAvailability { return .spellingOnly(appleAvailability) }
        if thermalPaused { return .spellingOnly(.thermalPause) }
        if settings.modelChecks[language] == false { return .spellingOnly(.languageOff) }
        return .model
    }

    public var canConfirmOnDevice: Bool {
        appleAvailability == nil && !thermalPaused
    }

    public var claudeTypingLanguages: [Language] {
        settings.claudeTypingLanguages(keyStored: claudeKeyPresent)
    }

    public func panel(requested: EngineKind?, app: String?) -> PanelRoute {
        let engine = requested ?? panelDefault(app: app)
        if keptOnThisMac(app), engine != .thisMac {
            return .unavailable(engine, .keptOnThisMac, alternatives: alternatives(to: engine, app: app))
        }
        guard let reason = unavailableReason(engine) else { return .use(engine) }
        return .unavailable(engine, reason, alternatives: alternatives(to: engine, app: app))
    }

    public func alternatives(to engine: EngineKind, app: String?) -> [EngineKind] {
        let candidates = keptOnThisMac(app) ? [EngineKind.thisMac] : EngineKind.allCases
        return candidates.filter { $0 != engine && unavailableReason($0) == nil }
    }

    public func pickerEngines(app: String?) -> [EngineKind] {
        if keptOnThisMac(app) { return [.thisMac] }
        return [.thisMac] + (settings.studio.isConfigured ? [.macStudio] : []) + [.claude]
    }

    public func panelDefault(app: String?) -> EngineKind {
        keptOnThisMac(app) ? .thisMac : settings.panelDefaultEngine
    }

    private func keptOnThisMac(_ app: String?) -> Bool {
        app.map { settings.mode(app: $0) == .thisMacOnly } ?? false
    }

    private func unavailableReason(_ engine: EngineKind) -> UnavailableReason? {
        switch engine {
        case .thisMac: appleAvailability
        case .macStudio: settings.studio.isConfigured ? nil : .studioNotConfigured
        case .claude: claudeKeyPresent ? nil : .claudeKeyMissing
        }
    }
}
