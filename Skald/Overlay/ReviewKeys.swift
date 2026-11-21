import CoreGraphics
import SkaldCore

/// The six review-mode keys, held only between `hold` and `release`: outside review mode Skald holds none of them.
final class ReviewKeys {
    static let bindings: [(key: ReviewMode.Key, hotkey: Hotkey)] = [
        (.next, Hotkey(keyCode: 124, modifiers: 0)),
        (.next, Hotkey(keyCode: 48, modifiers: 0)),
        (.previous, Hotkey(keyCode: 123, modifiers: 0)),
        (.accept, Hotkey(keyCode: 36, modifiers: 0)),
        (.dismiss, Hotkey(keyCode: 51, modifiers: 0)),
        (.leave, Hotkey(keyCode: 53, modifiers: 0)),
    ]

    /// How long a released key stays held whatever the system says of it; after that, only while it is physically down.
    static let lingerLimit: Duration = .seconds(1)

    /// `isDown` is also how a press that repeats while the key is held is told from a new one.
    private struct Slot {
        let key: ReviewMode.Key
        let token: HotkeyToken
        var isDown = false
    }

    /// How often a key still physically down is looked at again once the limit has passed.
    static let lingerCheck: Duration = .milliseconds(100)

    /// The system's own key state, which Carbon's events can lag or miss.
    static func systemKeyIsDown(_ code: UInt16) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
    }

    private let registrar: any KeyRegistering
    private let sleep: (Duration) async throws -> Void
    private let isDown: (UInt16) -> Bool
    /// Keyed by key code. After a `release` it holds only the keys still down.
    private var slots: [UInt16: Slot] = [:]
    private var pressed: (@MainActor (ReviewMode.Key) -> Void)?

    /// `isDown` reports whether a key is physically down, whatever Carbon last said of it.
    init(registrar: any KeyRegistering, sleep: @escaping (Duration) async throws -> Void, isDown: @escaping (UInt16) -> Bool) {
        self.registrar = registrar
        self.sleep = sleep
        self.isDown = isDown
    }

    var isHolding: Bool { pressed != nil }

    /// All six or none: false, with nothing held, when any registration fails. A key left over from the last
    /// `release` is freed first, and one that is still down stays down in its new slot.
    func hold(_ pressed: @escaping @MainActor (ReviewMode.Key) -> Void) -> Bool {
        if isHolding { return true }
        let stillDown = Set(slots.filter { $0.value.isDown || isDown($0.key) }.keys)
        freeAll()
        for binding in Self.bindings {
            let code = binding.hotkey.keyCode
            let token = registrar.register(
                binding.hotkey,
                action: { [weak self] in self?.pressed(code) },
                released: { [weak self] in self?.lifted(code) }
            )
            guard let token else {
                freeAll()
                return false
            }
            slots[code] = Slot(key: binding.key, token: token, isDown: stillDown.contains(code))
        }
        self.pressed = pressed
        return true
    }

    /// Frees every key that is up at once. A key that is down stays registered, swallowed and without effect, until it
    /// comes up, so its auto-repeat can't type into the app. Past `lingerLimit` a key Carbon never reported up is freed
    /// as soon as the system says it is up, and looked at again every `lingerCheck` while it is down.
    func release() {
        guard isHolding else { return }
        pressed = nil
        for (code, slot) in slots where !slot.isDown && !isDown(code) {
            registrar.unregister(slot.token)
            slots[code] = nil
        }
        let lingering = Set(slots.values.map(\.token))
        guard !lingering.isEmpty else { return }
        Task { [sleep] in
            try? await sleep(Self.lingerLimit)
            while self.freeUp(lingering) {
                do { try await sleep(Self.lingerCheck) } catch { return }
            }
        }
    }

    private func pressed(_ code: UInt16) {
        guard var slot = slots[code] else { return }
        let wasDown = slot.isDown
        slot.isDown = true
        slots[code] = slot
        if !wasDown { pressed?(slot.key) }
    }

    private func lifted(_ code: UInt16) {
        guard var slot = slots[code] else { return }
        slot.isDown = false
        slots[code] = slot
        if !isHolding { free([slot.token]) }
    }

    /// Frees those of `tokens` still held, so an earlier release's limit never frees a later hold's keys.
    private func free(_ tokens: Set<HotkeyToken>) {
        for (code, slot) in slots where tokens.contains(slot.token) {
            registrar.unregister(slot.token)
            slots[code] = nil
        }
    }

    /// Frees those of `tokens` still held whose key is physically up. True while one is left held.
    private func freeUp(_ tokens: Set<HotkeyToken>) -> Bool {
        var left = false
        for (code, slot) in slots where tokens.contains(slot.token) {
            if isDown(code) {
                left = true
            } else {
                registrar.unregister(slot.token)
                slots[code] = nil
            }
        }
        return left
    }

    private func freeAll() {
        free(Set(slots.values.map(\.token)))
    }
}
