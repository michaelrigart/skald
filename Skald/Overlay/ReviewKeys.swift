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

    /// How long a released key that never reports coming up stays held.
    static let lingerLimit: Duration = .seconds(1)

    /// `isDown` is also how a press that repeats while the key is held is told from a new one.
    private struct Slot {
        let key: ReviewMode.Key
        let token: HotkeyToken
        var isDown = false
    }

    private let registrar: any KeyRegistering
    private let sleep: (Duration) async throws -> Void
    /// Keyed by key code. After a `release` it holds only the keys still down.
    private var slots: [UInt16: Slot] = [:]
    private var pressed: (@MainActor (ReviewMode.Key) -> Void)?

    init(registrar: any KeyRegistering, sleep: @escaping (Duration) async throws -> Void) {
        self.registrar = registrar
        self.sleep = sleep
    }

    var isHolding: Bool { pressed != nil }

    /// All six or none: false, with nothing held, when any registration fails. A key left over from the last
    /// `release` is freed first, and one that is still down stays down in its new slot.
    func hold(_ pressed: @escaping @MainActor (ReviewMode.Key) -> Void) -> Bool {
        if isHolding { return true }
        let stillDown = Set(slots.filter(\.value.isDown).keys)
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
    /// comes up or `lingerLimit` passes, so its auto-repeat can't type into the app.
    func release() {
        guard isHolding else { return }
        pressed = nil
        for (code, slot) in slots where !slot.isDown {
            registrar.unregister(slot.token)
            slots[code] = nil
        }
        let lingering = Set(slots.values.map(\.token))
        guard !lingering.isEmpty else { return }
        Task { [sleep] in
            try? await sleep(Self.lingerLimit)
            self.free(lingering)
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

    private func freeAll() {
        free(Set(slots.values.map(\.token)))
    }
}
