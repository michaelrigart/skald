import Foundation
import Observation
import SkaldCore
import struct SwiftUI.Binding

/// The settings as Settings and the status item see them. Every change is saved, then handed to the
/// composition root, which applies it to text access, the router and the pipeline.
@Observable final class SettingsModel {
    private(set) var settings: Settings
    /// Why Apple's model can't run right now, when it can't; set by the composition root.
    var appleUnavailable: UnavailableReason?
    var thermalPaused = false
    private(set) var claudeKeyStored: Bool
    /// The launch-at-login state as the system reports it, when it differs from the switch.
    var loginItemNote: String?
    /// Why the panel's hotkey isn't working, when the system refused it; set by the composition root.
    var hotkeyNote: String?
    /// Why changes are not being kept, when they aren't.
    private(set) var saveNote: String?

    @ObservationIgnored var onChange: ((Settings) -> Void)?
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let keychain: KeychainStore

    init(settings: Settings, store: SettingsStore, keychain: KeychainStore, readOnly: Bool) {
        self.settings = settings
        self.store = store
        self.keychain = keychain
        claudeKeyStored = keychain.containsValue()
        saveNote = readOnly ? Self.readOnlyNote : nil
    }

    /// Why typing checks are spelling only right now, when they are.
    var spellingOnlyReason: UnavailableReason? {
        appleUnavailable ?? (thermalPaused ? .thermalPause : nil)
    }

    func update(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        do {
            try store.save(next)
            saveNote = nil
        } catch SettingsStoreError.readOnly {
            saveNote = Self.readOnlyNote
        } catch {
            Log.app.notice("settings not saved: \(String(describing: error), privacy: .private)")
            saveNote = "Skald couldn't save your settings. Changes last until Skald quits."
        }
        onChange?(next)
    }

    func binding<Value>(_ path: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: path] }, set: { value in self.update { $0[keyPath: path] = value } })
    }

    // MARK: Pause

    func pauseForAnHour(now: Date = .now) {
        update { $0.pausedUntil = now.addingTimeInterval(60 * 60) }
    }

    func resume() {
        update { $0.pausedUntil = nil }
    }

    // MARK: Apps

    static let shippedOffApps = Settings.defaultOffApps

    /// Stores an override only where it differs from the shipped default.
    func setApp(_ bundleID: String, enabled: Bool) {
        update {
            if enabled == !Settings.defaultOffApps.contains(bundleID) {
                $0.appOverrides[bundleID] = nil
            } else {
                $0.appOverrides[bundleID] = enabled
            }
        }
    }

    // MARK: Words

    func addNeverTouch(_ word: String) {
        update { $0.addNeverTouch(word) }
    }

    func removeNeverTouch(_ word: String) {
        update { $0.removeNeverTouch(word) }
    }

    // MARK: Languages

    func modelChecks(_ language: Language) -> Binding<Bool> {
        Binding(get: { self.settings.modelChecks[language] ?? false }, set: { on in self.update { $0.modelChecks[language] = on } })
    }

    func typingChecks(_ language: Language) -> Binding<Bool> {
        Binding(get: { self.settings.typingChecks[language] ?? false }, set: { on in self.update { $0.typingChecks[language] = on } })
    }

    // MARK: Claude key

    /// Stores the key; the field that held it is cleared by the caller, and the key is never shown again.
    @discardableResult
    func saveClaudeKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try keychain.write(trimmed)
        } catch {
            return false
        }
        claudeKeyChanged()
        return true
    }

    @discardableResult
    func removeClaudeKey() -> Bool {
        do {
            try keychain.delete()
        } catch {
            return false
        }
        claudeKeyChanged()
        return true
    }

    /// The cached presence the router reads, so routing never asks the Keychain.
    private func claudeKeyChanged() {
        claudeKeyStored = keychain.containsValue()
        onChange?(settings)
    }

    private static let readOnlyNote = "These settings were saved by a newer Skald, so changes last only until Skald quits."
}
