import SkaldCore
@testable import Skald

/// Holds hotkeys in memory, so a test never registers a real one. `press` and `lift` stand in for the system's events.
final class FakeRegistrar: KeyRegistering {
    struct Registration {
        let token: HotkeyToken
        let keyCode: UInt16
        let modifiers: UInt32
        let action: @MainActor () -> Void
        let released: (@MainActor () -> Void)?
    }

    private let refusing: Set<UInt16>
    private var issued: UInt32 = 0
    private(set) var held: [Registration] = []

    init(refusing: Set<UInt16> = []) {
        self.refusing = refusing
    }

    func register(_ h: Hotkey, action: @escaping @MainActor () -> Void, released: (@MainActor () -> Void)?) -> HotkeyToken? {
        guard !refusing.contains(h.keyCode) else { return nil }
        issued += 1
        let token = HotkeyToken(issued)
        held.append(Registration(token: token, keyCode: h.keyCode, modifiers: h.modifiers, action: action, released: released))
        return token
    }

    func unregister(_ token: HotkeyToken) {
        held.removeAll { $0.token == token }
    }

    func press(_ keyCode: UInt16) {
        held.first { $0.keyCode == keyCode }?.action()
    }

    func lift(_ keyCode: UInt16) {
        held.first { $0.keyCode == keyCode }?.released?()
    }
}
