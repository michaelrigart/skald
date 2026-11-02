import Foundation

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case thisMac, macStudio, claude
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

    public var keyCode: UInt16
    public var modifiers: UInt32

    public init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = Hotkey(keyCode: gKeyCode, modifiers: controlModifier | optionModifier)
}

public struct Settings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

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
    public var appOverrides: [String: Bool] = [:]
    public private(set) var neverTouch: [String] = []
    public var modelChecks: [Language: Bool] = Settings.allLanguagesOn
    public var typingChecks: [Language: Bool] = Settings.allLanguagesOn
    public var panelDefaultEngine = EngineKind.thisMac
    public var studio = StudioEndpoint()
    public var claudeModel = "claude-opus-5-5"

    public init() {}

    public func isEnabled(app bundleID: String) -> Bool {
        appOverrides[bundleID] ?? !Settings.defaultOffApps.contains(bundleID)
    }

    public mutating func addNeverTouch(_ word: String) {
        neverTouch = Settings.normalised(neverTouch + [word])
    }

    private static let allLanguagesOn = Dictionary(uniqueKeysWithValues: Language.allCases.map { ($0, true) })

    private static func normalised(_ words: [String]) -> [String] {
        var seen = Set<String>()
        let unique = words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func languageChecks(_ stored: [Language: Bool]?) -> [Language: Bool] {
        allLanguagesOn.merging(stored ?? [:]) { _, new in new }
    }

    private enum CodingKeys: String, CodingKey {
        case version, launchAtLogin, panelHotkey, pausedUntil, appOverrides, neverTouch
        case modelChecks, typingChecks, panelDefaultEngine, studio, claudeModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        panelHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .panelHotkey) ?? defaults.panelHotkey
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        appOverrides = try container.decodeIfPresent([String: Bool].self, forKey: .appOverrides) ?? defaults.appOverrides
        neverTouch = Settings.normalised(try container.decodeIfPresent([String].self, forKey: .neverTouch) ?? [])
        modelChecks = Settings.languageChecks(try container.decodeIfPresent([Language: Bool].self, forKey: .modelChecks))
        typingChecks = Settings.languageChecks(try container.decodeIfPresent([Language: Bool].self, forKey: .typingChecks))
        panelDefaultEngine = try container.decodeIfPresent(EngineKind.self, forKey: .panelDefaultEngine) ?? defaults.panelDefaultEngine
        studio = try container.decodeIfPresent(StudioEndpoint.self, forKey: .studio) ?? defaults.studio
        claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel) ?? defaults.claudeModel
    }
}
