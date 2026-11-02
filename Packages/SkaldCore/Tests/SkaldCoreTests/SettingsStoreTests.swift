import Foundation
import Testing
@testable import SkaldCore

private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("skald-settings-\(UUID().uuidString)")
}

private func settingsFile(_ directory: URL) -> URL {
    directory.appendingPathComponent("settings.json")
}

private func write(_ text: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: settingsFile(directory))
}

@Test func settingsRoundTrip() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var settings = Settings()
    settings.launchAtLogin = false
    settings.appOverrides["com.mitchellh.ghostty"] = true
    settings.addNeverTouch("Talos")
    settings.modelChecks[.nl] = false
    settings.panelDefaultEngine = .claude
    settings.studio = StudioEndpoint(api: .openAICompatible, baseURL: "http://studio.local:1234", model: "m")
    settings.pausedUntil = Date(timeIntervalSince1970: 1_800_000_000)
    let store = SettingsStore(directory: directory)
    try store.save(settings)
    guard case .loaded(let loaded) = store.load() else {
        Issue.record("expected .loaded")
        return
    }
    #expect(loaded == settings)
}

@Test func missingFileLoadsFreshDefaults() {
    let directory = makeDirectory()
    guard case .fresh(let settings) = SettingsStore(directory: directory).load() else {
        Issue.record("expected .fresh")
        return
    }
    #expect(settings.version == 1)
    #expect(settings.launchAtLogin)
    #expect(settings.panelHotkey == Hotkey.default)
    #expect(settings.panelHotkey.keyCode == 5)
    #expect(settings.panelHotkey.modifiers == 6144)
    #expect(settings.pausedUntil == nil)
    #expect(settings.appOverrides.isEmpty)
    #expect(settings.neverTouch.isEmpty)
    #expect(Language.allCases.allSatisfy { settings.modelChecks[$0] == true && settings.typingChecks[$0] == true })
    #expect(settings.panelDefaultEngine == .thisMac)
    #expect(settings.studio == StudioEndpoint())
    #expect(settings.claudeModel == "claude-opus-5-5")
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func garbageIsMovedAsideAndRecovered() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write("{ not json", to: directory)
    guard case .recoveredFromCorrupt(let settings) = SettingsStore(directory: directory).load() else {
        Issue.record("expected .recoveredFromCorrupt")
        return
    }
    #expect(settings == Settings())
    let corrupt = directory.appendingPathComponent("settings.corrupt.json")
    #expect(try String(contentsOf: corrupt, encoding: .utf8) == "{ not json")
    #expect(!FileManager.default.fileExists(atPath: settingsFile(directory).path))
}

@Test func futureVersionIsReadOnlyAndNeverOverwritten() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = #"{"version": 2, "somethingNew": true}"#
    try write(original, to: directory)
    let before = try Data(contentsOf: settingsFile(directory))
    let store = SettingsStore(directory: directory)
    guard case .futureVersion(let version) = store.load() else {
        Issue.record("expected .futureVersion")
        return
    }
    #expect(version == 2)
    #expect(throws: SettingsStoreError.readOnly) { try store.save(Settings()) }
    #expect(try Data(contentsOf: settingsFile(directory)) == before)
}

@Test func versionOneFileMissingANewerFieldLoadsWithTheDefault() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(#"{"version": 1, "launchAtLogin": false}"#, to: directory)
    guard case .loaded(let settings) = SettingsStore(directory: directory).load() else {
        Issue.record("expected .loaded")
        return
    }
    #expect(settings.launchAtLogin == false)
    #expect(Language.allCases.allSatisfy { settings.typingChecks[$0] == true })
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.corrupt.json").path))
}

@Test func languageChecksEncodeAsObjectsKeyedByCode() throws {
    let data = try JSONEncoder().encode(Settings())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let checks = try #require(object["modelChecks"] as? [String: Bool])
    #expect(checks == ["en": true, "nl": true, "fr": true])
}

@Test func defaultOffAppsAreOffUnlessOverridden() {
    var settings = Settings()
    #expect(!settings.isEnabled(app: "com.mitchellh.ghostty"))
    #expect(settings.isEnabled(app: "com.apple.Notes"))
    settings.appOverrides["com.mitchellh.ghostty"] = true
    #expect(settings.isEnabled(app: "com.mitchellh.ghostty"))
    settings.appOverrides["com.apple.Notes"] = false
    #expect(!settings.isEnabled(app: "com.apple.Notes"))
}

@Test func neverTouchStaysSortedAndUnique() {
    var settings = Settings()
    settings.addNeverTouch("Talos")
    settings.addNeverTouch("talos")
    #expect(settings.neverTouch == ["Talos"])
    settings.addNeverTouch("kubectl")
    settings.addNeverTouch("Argo")
    #expect(settings.neverTouch == ["Argo", "kubectl", "Talos"])
}

@Test func decodedNeverTouchIsNormalised() throws {
    let json = #"{"version": 1, "neverTouch": ["zeta", "Talos", "talos", "Alpha"]}"#
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.neverTouch == ["Alpha", "Talos", "zeta"])
}

@Test func studioIsConfiguredOnlyWithAnHTTPURLAndAModel() {
    #expect(!StudioEndpoint().isConfigured)
    #expect(StudioEndpoint(api: .ollama, baseURL: "http://host:11434", model: "m").isConfigured)
    #expect(!StudioEndpoint(api: .ollama, baseURL: "http://host:11434", model: "").isConfigured)
    #expect(!StudioEndpoint(api: .ollama, baseURL: "ftp://host", model: "m").isConfigured)
    #expect(!StudioEndpoint(api: .ollama, baseURL: "not a url", model: "m").isConfigured)
}
