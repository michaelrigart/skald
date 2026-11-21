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

private let v1File = """
{"version": 1, "launchAtLogin": false, "panelHotkey": {"keyCode": 3, "modifiers": 4096},
 "pausedUntil": "2027-01-15T08:00:00.000Z", "appOverrides": {"com.mitchellh.ghostty": true, "com.apple.Notes": false},
 "neverTouch": ["Brightline", "Talos"], "modelChecks": {"en": true, "nl": true, "fr": false},
 "typingChecks": {"en": true, "nl": true, "fr": true}, "panelDefaultEngine": "claude",
 "studio": {"api": "openAICompatible", "baseURL": "http://studio.local:1234", "model": "m"},
 "claudeModel": "claude-sonnet-5-5"}
"""

@Test func settingsRoundTrip() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var settings = Settings()
    settings.launchAtLogin = false
    settings.appOverrides["com.mitchellh.ghostty"] = .on
    settings.appOverrides["com.apple.Notes"] = .thisMacOnly
    settings.addNeverTouch("Talos")
    settings.modelChecks[.nl] = false
    settings.panelDefaultEngine = .claude
    settings.studio = StudioEndpoint(api: .openAICompatible, baseURL: "http://studio.local:1234", model: "m")
    settings.pausedUntil = Date(timeIntervalSince1970: 1_800_000_000)
    settings.claudeTyping = true
    settings.claudeLanguages = [.nl: true, .fr: false]
    settings.claudeTypingModel = "claude-sonnet-5-5"
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
    #expect(settings.version == 2)
    #expect(settings.launchAtLogin)
    #expect(settings.panelHotkey == Hotkey.default)
    #expect(settings.panelHotkey.keyCode == 5)
    #expect(settings.panelHotkey.modifiers == 6144)
    #expect(settings.pausedUntil == nil)
    #expect(settings.appOverrides.isEmpty)
    #expect(settings.neverTouch.isEmpty)
    #expect(settings.modelChecks == [.en: true, .nl: false, .fr: false])
    #expect(settings.typingChecks == [.en: true, .nl: true, .fr: false])
    #expect(settings.panelDefaultEngine == .thisMac)
    #expect(settings.studio == StudioEndpoint())
    #expect(settings.claudeModel == "claude-opus-5-5")
    #expect(!settings.claudeTyping)
    #expect(settings.claudeLanguages == [.nl: true, .fr: true])
    #expect(settings.claudeTypingModel == "claude-haiku-5-5")
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
    let original = #"{"version": 3, "somethingNew": true}"#
    try write(original, to: directory)
    let before = try Data(contentsOf: settingsFile(directory))
    let store = SettingsStore(directory: directory)
    guard case .futureVersion(let version) = store.load() else {
        Issue.record("expected .futureVersion")
        return
    }
    #expect(version == 3)
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
    #expect(settings.typingChecks == Settings().typingChecks)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.corrupt.json").path))
}

@Test func languageChecksEncodeAsObjectsKeyedByCode() throws {
    let data = try JSONEncoder().encode(Settings())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let checks = try #require(object["modelChecks"] as? [String: Bool])
    #expect(checks == ["en": true, "nl": false, "fr": false])
}

@Test func defaultOffAppsAreOffUnlessOverridden() {
    var settings = Settings()
    #expect(settings.mode(app: "com.mitchellh.ghostty") == .off)
    #expect(!settings.isEnabled(app: "com.mitchellh.ghostty"))
    #expect(settings.mode(app: "com.apple.Notes") == .on)
    #expect(settings.isEnabled(app: "com.apple.Notes"))
    settings.appOverrides["com.mitchellh.ghostty"] = .on
    #expect(settings.isEnabled(app: "com.mitchellh.ghostty"))
    settings.appOverrides["com.apple.Notes"] = .off
    #expect(!settings.isEnabled(app: "com.apple.Notes"))
    settings.appOverrides["com.apple.Notes"] = .thisMacOnly
    #expect(settings.mode(app: "com.apple.Notes") == .thisMacOnly)
    #expect(settings.isEnabled(app: "com.apple.Notes"))
}

@Test func aV1FileIsReadWithoutLoss() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(v1File, to: directory)
    guard case .loaded(let settings) = SettingsStore(directory: directory).load() else {
        Issue.record("expected .loaded")
        return
    }
    #expect(settings.version == 2)
    #expect(settings.launchAtLogin == false)
    #expect(settings.panelHotkey == Hotkey(keyCode: 3, modifiers: 4096))
    #expect(settings.pausedUntil == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(settings.appOverrides == ["com.mitchellh.ghostty": .on, "com.apple.Notes": .off])
    #expect(settings.neverTouch == ["Brightline", "Talos"])
    #expect(settings.modelChecks == [.en: true, .nl: true, .fr: false])
    #expect(settings.typingChecks == [.en: true, .nl: true, .fr: true])
    #expect(settings.panelDefaultEngine == .claude)
    #expect(settings.studio == StudioEndpoint(api: .openAICompatible, baseURL: "http://studio.local:1234", model: "m"))
    #expect(settings.claudeModel == "claude-sonnet-5-5")
    #expect(!settings.claudeTyping)
    #expect(settings.claudeLanguages == [.nl: true, .fr: true])
    #expect(settings.claudeTypingModel == "claude-haiku-5-5")
}

@Test func aV1FileSavedAgainIsWrittenAsVersion2() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(v1File, to: directory)
    let store = SettingsStore(directory: directory)
    guard case .loaded(let first) = store.load() else {
        Issue.record("expected .loaded")
        return
    }
    try store.save(first)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile(directory))) as? [String: Any])
    #expect(object["version"] as? Int == 2)
    #expect(object["appOverrides"] as? [String: String] == ["com.apple.Notes": "off", "com.mitchellh.ghostty": "on"])
    #expect(store.load() == .loaded(first))
}

@Test func anUnknownAppModeDropsOnlyThatEntry() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(#"{"version": 2, "appOverrides": {"a": "sometimes", "b": "thisMacOnly"}, "neverTouch": ["Talos"]}"#, to: directory)
    guard case .loaded(let settings) = SettingsStore(directory: directory).load() else {
        Issue.record("expected .loaded")
        return
    }
    #expect(settings.appOverrides == ["b": .thisMacOnly])
    #expect(settings.neverTouch == ["Talos"])
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

@Test func removingANeverTouchWordIgnoresCase() {
    var settings = Settings()
    settings.addNeverTouch("Talos")
    settings.addNeverTouch("Argo")
    settings.removeNeverTouch("talos")
    #expect(settings.neverTouch == ["Argo"])
}

@Test func neverTouchWordsAreTrimmedAndEmptyOnesDropped() {
    var settings = Settings()
    settings.addNeverTouch("Talos")
    settings.addNeverTouch(" Talos")
    settings.addNeverTouch("   ")
    #expect(settings.neverTouch == ["Talos"])
}

@Test func partialLanguageMapKeepsOtherDefaults() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"modelChecks":{"nl":true}}"#.utf8))
    #expect(settings.modelChecks == [.en: true, .fr: false, .nl: true])
}

@Test func unknownValuesFallBackWithoutDiscardingTheFile() throws {
    let json = #"{"launchAtLogin":false,"modelChecks":{"de":false},"panelDefaultEngine":"quantum","studio":{"api":"grpc","model":"m"}}"#
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.launchAtLogin == false)
    #expect(settings.modelChecks == Settings().modelChecks)
    #expect(settings.panelDefaultEngine == .thisMac)
    #expect(settings.studio.api == .ollama)
    #expect(settings.studio.model == "m")
}

@Test func aSecondCorruptionReplacesTheFirstCorruptCopy() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(directory: directory)
    try write("first garbage", to: directory)
    _ = store.load()
    try write("second garbage", to: directory)
    guard case .recoveredFromCorrupt = store.load() else {
        Issue.record("expected .recoveredFromCorrupt")
        return
    }
    let corrupt = directory.appendingPathComponent("settings.corrupt.json")
    #expect(try String(contentsOf: corrupt, encoding: .utf8) == "second garbage")
    try store.save(Settings())
}

@Test func unreadableFileLeavesTheStoreReadOnly() throws {
    let directory = makeDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settingsFile(directory).path)
        try? FileManager.default.removeItem(at: directory)
    }
    try write("{}", to: directory)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settingsFile(directory).path)
    let store = SettingsStore(directory: directory)
    guard case .recoveredFromCorrupt(let settings) = store.load() else {
        Issue.record("expected .recoveredFromCorrupt")
        return
    }
    #expect(settings == Settings())
    #expect(throws: SettingsStoreError.readOnly) { try store.save(Settings()) }
}

@Test func aSuccessfulLoadClearsTheReadOnlyFlag() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(directory: directory)
    try write(#"{"version": 3}"#, to: directory)
    _ = store.load()
    try write(#"{"version": 2}"#, to: directory)
    _ = store.load()
    try store.save(Settings())
}

@Test func fractionalSecondsSurviveARoundTrip() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var settings = Settings()
    settings.pausedUntil = Date(timeIntervalSince1970: 1_800_000_000.25)
    let store = SettingsStore(directory: directory)
    try store.save(settings)
    #expect(store.load() == .loaded(settings))
}

@Test func hiddenKindsAndTheReviewShortcutRoundTrip() throws {
    var settings = Settings()
    settings.hide(.verbForm); settings.hide(.punctuation); settings.hide(.grammar); settings.hide(.spelling)
    settings.reviewHotkey = Hotkey(keyCode: 45, modifiers: 0x0100)
    #expect(settings.hiddenKinds == [.punctuation, .verbForm])
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
    #expect(json?["hiddenKinds"] as? [String] == ["punctuation", "verbForm"])
    #expect(json?["version"] as? Int == 2)
    #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
}

@Test func showingAKindRemovesItFromTheHiddenOnes() {
    var settings = Settings()
    settings.hide(.capital); settings.hide(.accent)
    settings.show(.capital)
    #expect(settings.hiddenKinds == [.accent])
}

@Test func aStage1FileReadsWithNothingHiddenAndTheDefaultShortcut() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"version":2,"claudeTyping":true}"#.utf8))
    #expect(settings.hiddenKinds == [])
    #expect(settings.reviewHotkey == .review)
    #expect(settings.reviewHotkey == Hotkey(keyCode: 15, modifiers: 6144))
    #expect(settings.claudeTyping)
}

@Test func anUnknownOrUnhideableStoredKindIsDropped() throws {
    let stored = #"{"version":2,"hiddenKinds":["verbForm","tone","grammar","verbForm","accent"]}"#
    let settings = try JSONDecoder().decode(Settings.self, from: Data(stored.utf8))
    #expect(settings.hiddenKinds == [.accent, .verbForm])
}

@Test func aMalformedReviewShortcutReadsAsTheDefaultAndKeepsTheRest() throws {
    for stored in [#""x""#, #"{"keyCode":15}"#] {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(#"{"version":2,"neverTouch":["Brightline"],"reviewHotkey":\#(stored)}"#, to: directory)
        guard case .loaded(let settings) = SettingsStore(directory: directory).load() else {
            Issue.record("expected .loaded for \(stored)")
            continue
        }
        #expect(settings.reviewHotkey == .review)
        #expect(settings.neverTouch == ["Brightline"])
    }
}

@Test func malformedClaudeValuesReadAsTheirDefaultsAndKeepTheRest() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(#"{"version":2,"claudeTyping":"true","claudeTypingModel":42,"neverTouch":["Brightline"]}"#, to: directory)
    guard case .loaded(let settings) = SettingsStore(directory: directory).load() else {
        Issue.record("expected .loaded")
        return
    }
    #expect(!settings.claudeTyping)
    #expect(settings.claudeTypingModel == "claude-haiku-5-5")
    #expect(settings.neverTouch == ["Brightline"])
}
