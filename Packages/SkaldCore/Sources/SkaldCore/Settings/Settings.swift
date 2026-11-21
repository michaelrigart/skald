import Foundation

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case thisMac, macStudio, claude
}

public enum AppMode: String, Codable, CaseIterable, Sendable {
    case on, thisMacOnly, off

    fileprivate struct Stored: Decodable {
        let mode: AppMode?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                mode = flag ? .on : .off
            } else if let raw = try? container.decode(String.self) {
                mode = AppMode(rawValue: raw)
            } else {
                mode = nil
            }
        }
    }
}

public struct StudioEndpoint: Codable, Equatable, Sendable {
    public enum API: String, Codable, Sendable {
        case ollama, openAICompatible
    }

    public var api: API
    public var baseURL: String
    public var model: String

    public init(api: API = .ollama, baseURL: String = "", model: String = "") {
        self.api = api
        self.baseURL = baseURL
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case api, baseURL, model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StudioEndpoint()
        api = Settings.lenient(API.self, in: container, forKey: .api) ?? defaults.api
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
    }

    public var isConfigured: Bool {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return !model.isEmpty
    }
}

public struct Hotkey: Codable, Equatable, Sendable {
    static let controlModifier: UInt32 = 0x1000
    static let optionModifier: UInt32 = 0x0800
    static let gKeyCode: UInt16 = 5
    static let rKeyCode: UInt16 = 15

    public var keyCode: UInt16
    public var modifiers: UInt32

    public init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = Hotkey(keyCode: gKeyCode, modifiers: controlModifier | optionModifier)
    public static let review = Hotkey(keyCode: rKeyCode, modifiers: controlModifier | optionModifier)
}

public struct Settings: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public static let defaultOffApps: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "dev.zed.Zed",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.michaelrigart.skald",
    ]

    public var version = Settings.currentVersion
    public var launchAtLogin = true
    public var panelHotkey = Hotkey.default
    public var pausedUntil: Date?
    public var appOverrides: [String: AppMode] = [:]
    public private(set) var neverTouch: [String] = []
    public private(set) var hiddenKinds: [IssueKind] = []
    public var reviewHotkey = Hotkey.review
    public var modelChecks: [Language: Bool] = Settings.defaultModelChecks
    public var typingChecks: [Language: Bool] = Settings.defaultTypingChecks
    public var panelDefaultEngine = EngineKind.thisMac
    public var studio = StudioEndpoint()
    public var claudeModel = "claude-opus-5-5"
    public var claudeTyping = false
    public var claudeLanguages: [Language: Bool] = Settings.defaultClaudeLanguages
    public var claudeTypingModel = "claude-haiku-5-5"

    public init() {}

    public static func defaultMode(app bundleID: String) -> AppMode {
        defaultOffApps.contains(bundleID) ? .off : .on
    }

    public func mode(app bundleID: String) -> AppMode {
        appOverrides[bundleID] ?? Settings.defaultMode(app: bundleID)
    }

    public func isEnabled(app bundleID: String) -> Bool {
        mode(app: bundleID) != .off
    }

    /// Whether Claude checks while typing is on: the switch, and a stored key.
    public func claudeTypingIsOn(keyStored: Bool) -> Bool {
        claudeTyping && keyStored
    }

    /// The languages Claude takes while typing, whatever the app: never English.
    public func claudeTypingLanguages(keyStored: Bool) -> [Language] {
        guard claudeTypingIsOn(keyStored: keyStored) else { return [] }
        return [Language.nl, .fr].filter { claudeLanguages[$0] == true }
    }

    public func claudeTakes(_ language: Language, keyStored: Bool) -> Bool {
        claudeTypingLanguages(keyStored: keyStored).contains(language)
    }

    public mutating func addNeverTouch(_ word: String) {
        neverTouch = Settings.normalised(neverTouch + [word])
    }

    public mutating func removeNeverTouch(_ word: String) {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        neverTouch.removeAll { $0.lowercased() == key }
    }

    /// Hides a kind of issue; a kind that isn't hideable is ignored.
    public mutating func hide(_ kind: IssueKind) {
        hiddenKinds = Settings.hideable(hiddenKinds + [kind])
    }

    public mutating func show(_ kind: IssueKind) {
        hiddenKinds.removeAll { $0 == kind }
    }

    /// Takes the fields that only change what is shown (`hiddenKinds`, `reviewHotkey`) from `other`.
    mutating func restoreDisplay(from other: Settings) {
        hiddenKinds = other.hiddenKinds
        reviewHotkey = other.reviewHotkey
    }

    private static let defaultModelChecks: [Language: Bool] = [.en: true, .nl: false, .fr: false]
    private static let defaultTypingChecks: [Language: Bool] = [.en: true, .nl: true, .fr: false]
    private static let defaultClaudeLanguages: [Language: Bool] = [.nl: true, .fr: true]

    private static func normalised(_ words: [String]) -> [String] {
        var seen = Set<String>()
        let unique = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func hideable(_ kinds: [IssueKind]) -> [IssueKind] {
        Array(Set(kinds.filter(\.isHideable))).sorted { $0.rawValue < $1.rawValue }
    }

    fileprivate static func lenient<Value: RawRepresentable<String>, Key: CodingKey>(
        _ type: Value.Type, in container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> Value? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return Value(rawValue: raw)
    }

    private static func languageChecks(
        in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys, defaults: [Language: Bool]
    ) -> [Language: Bool] {
        guard let stored = (try? container.decodeIfPresent([String: Bool].self, forKey: key)) ?? nil else { return defaults }
        var checks = defaults
        for (code, value) in stored {
            if let language = Language(rawValue: code) { checks[language] = value }
        }
        return checks
    }

    private enum CodingKeys: String, CodingKey {
        case version, launchAtLogin, panelHotkey, pausedUntil, appOverrides, neverTouch, hiddenKinds, reviewHotkey
        case modelChecks, typingChecks, panelDefaultEngine, studio, claudeModel
        case claudeTyping, claudeLanguages, claudeTypingModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        version = Settings.currentVersion
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        panelHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .panelHotkey) ?? defaults.panelHotkey
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        let storedOverrides = try container.decodeIfPresent([String: AppMode.Stored].self, forKey: .appOverrides) ?? [:]
        appOverrides = storedOverrides.compactMapValues(\.mode)
        neverTouch = Settings.normalised(try container.decodeIfPresent([String].self, forKey: .neverTouch) ?? [])
        let storedKinds = (try? container.decodeIfPresent([String].self, forKey: .hiddenKinds)) ?? nil
        hiddenKinds = Settings.hideable((storedKinds ?? []).compactMap { IssueKind(rawValue: $0) })
        reviewHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .reviewHotkey) ?? defaults.reviewHotkey
        modelChecks = Settings.languageChecks(in: container, forKey: .modelChecks, defaults: defaults.modelChecks)
        typingChecks = Settings.languageChecks(in: container, forKey: .typingChecks, defaults: defaults.typingChecks)
        panelDefaultEngine = Settings.lenient(EngineKind.self, in: container, forKey: .panelDefaultEngine) ?? defaults.panelDefaultEngine
        studio = try container.decodeIfPresent(StudioEndpoint.self, forKey: .studio) ?? defaults.studio
        claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel) ?? defaults.claudeModel
        claudeTyping = try container.decodeIfPresent(Bool.self, forKey: .claudeTyping) ?? defaults.claudeTyping
        claudeLanguages = Settings.languageChecks(in: container, forKey: .claudeLanguages, defaults: defaults.claudeLanguages)
        claudeTypingModel = try container.decodeIfPresent(String.self, forKey: .claudeTypingModel) ?? defaults.claudeTypingModel
    }
}
