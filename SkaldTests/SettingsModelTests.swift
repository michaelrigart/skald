import Foundation
import SkaldCore
import Testing
@testable import Skald

/// An account no real Skald item uses, emptied before and after each test.
private let testKeychain = KeychainStore(service: "com.michaelrigart.skald.tests", account: "settings-model-tests")

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("skald-tests-\(UUID().uuidString)", isDirectory: true)
}

/// Every `onChange` call, with what the store held on disk at that moment.
private final class ChangeLog {
    private(set) var settings: [Settings] = []
    private(set) var savedAtThatMoment: [SettingsStore.LoadOutcome] = []

    func attach(to model: SettingsModel, store: SettingsStore) {
        model.onChange = { [self] in
            settings.append($0)
            savedAtThatMoment.append(store.load())
        }
    }
}

@Suite(.serialized) struct SettingsModelTests {
    init() throws {
        try testKeychain.delete()
    }

    private func makeModel(_ directory: URL = temporaryDirectory(), readOnly: Bool = false) -> (SettingsModel, SettingsStore) {
        let store = SettingsStore(directory: directory)
        if readOnly { _ = store.load() }
        return (SettingsModel(settings: Settings(), store: store, keychain: testKeychain, readOnly: readOnly), store)
    }

    @Test func anAppOverrideIsStoredOnlyWhereItDiffersFromTheShippedDefault() {
        let (model, _) = makeModel()
        model.setApp("com.apple.Notes", enabled: false)
        #expect(model.settings.appOverrides == ["com.apple.Notes": false])
        model.setApp("com.apple.Notes", enabled: true)
        #expect(model.settings.appOverrides.isEmpty)
        model.setApp("com.apple.Terminal", enabled: true)
        #expect(model.settings.appOverrides == ["com.apple.Terminal": true])
        model.setApp("com.apple.Terminal", enabled: false)
        #expect(model.settings.appOverrides.isEmpty)
    }

    @Test func aChangeIsSavedBeforeOnChangeHearsOfIt() {
        let (model, store) = makeModel()
        let log = ChangeLog()
        log.attach(to: model, store: store)
        model.addNeverTouch("Brightline")
        #expect(log.settings.map(\.neverTouch) == [["Brightline"]])
        #expect(log.savedAtThatMoment == [.loaded(model.settings)])
    }

    @Test func anUpdateThatChangesNothingIsNeitherSavedNorReported() {
        let (model, store) = makeModel()
        let log = ChangeLog()
        log.attach(to: model, store: store)
        model.resume()
        #expect(log.settings.isEmpty)
        #expect(store.load() == .fresh(Settings()))
    }

    @Test func aReadOnlyStoreKeepsTheChangeInMemoryAndSaysSo() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        try Data(#"{"version": 99}"#.utf8).write(to: file)
        let (model, store) = makeModel(directory, readOnly: true)
        let log = ChangeLog()
        log.attach(to: model, store: store)
        model.addNeverTouch("Northwind")
        #expect(model.settings.neverTouch == ["Northwind"])
        #expect(model.saveNote != nil)
        #expect(log.settings.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"version": 99}"#)
    }

    @Test func aFailedSaveKeepsTheChangeInMemoryAndSaysSo() throws {
        let blocker = temporaryDirectory()
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let (model, _) = makeModel(blocker.appendingPathComponent("settings", isDirectory: true))
        var reported = 0
        model.onChange = { _ in reported += 1 }
        model.addNeverTouch("Northwind")
        #expect(model.settings.neverTouch == ["Northwind"])
        #expect(model.saveNote != nil)
        #expect(reported == 1)
    }

    @Test func theClaudeKeyGoesOnlyToTheKeychainAndTheModelKeepsItsPresence() throws {
        defer { try? testKeychain.delete() }
        let secret = "sk-test-never-shown"
        let (model, store) = makeModel()
        let log = ChangeLog()
        log.attach(to: model, store: store)
        #expect(!model.claudeKeyStored)
        #expect(model.saveClaudeKey("  \(secret)\n"))
        #expect(testKeychain.read() == secret)
        #expect(model.claudeKeyStored)
        let held = String(describing: Mirror(reflecting: model).children.map(\.value))
        #expect(!held.contains(secret))
        let reported = try log.settings.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        #expect(reported.count == 1)
        #expect(!reported.contains { $0.contains(secret) })
        #expect(model.removeClaudeKey())
        #expect(!model.claudeKeyStored)
        #expect(testKeychain.read() == nil)
    }

    @Test func aBlankKeyIsNeitherStoredNorReported() {
        let (model, store) = makeModel()
        let log = ChangeLog()
        log.attach(to: model, store: store)
        #expect(!model.saveClaudeKey(" \n"))
        #expect(!model.claudeKeyStored)
        #expect(testKeychain.read() == nil)
        #expect(log.settings.isEmpty)
    }
}
