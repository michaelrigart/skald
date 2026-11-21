import AppKit
import Carbon.HIToolbox
import SkaldCore

/// One registered hotkey, to release it alone.
struct HotkeyToken: Hashable {
    let id: UInt32

    init(_ id: UInt32) {
        self.id = id
    }
}

protocol KeyRegistering: AnyObject {
    /// nil: the system refused it. `released` is called when the key comes up.
    func register(_ h: Hotkey, action: @escaping @MainActor () -> Void, released: (@MainActor () -> Void)?) -> HotkeyToken?
    func unregister(_ token: HotkeyToken)
}

/// Global hotkeys through Carbon's `RegisterEventHotKey`, which needs no Accessibility or Input Monitoring grant.
final class HotkeyCenter: KeyRegistering {
    private static let signature: OSType = 0x534B_4C44 // "SKLD"

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var releases: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    deinit {
        MainActor.assumeIsolated {
            unregisterAll()
            if let handler { RemoveEventHandler(handler) }
        }
    }

    /// nil when the system refused the hotkey, for one it reserves or another app holds.
    @discardableResult
    func register(_ h: Hotkey, action: @escaping @MainActor () -> Void) -> HotkeyToken? {
        register(h, action: action, released: nil)
    }

    func register(_ h: Hotkey, action: @escaping @MainActor () -> Void, released: (@MainActor () -> Void)?) -> HotkeyToken? {
        guard installHandler() else { return nil }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(h.keyCode), h.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Log.app.notice("hotkey not registered: OSStatus \(status)")
            return nil
        }
        refs[id] = ref
        actions[id] = action
        releases[id] = released
        return HotkeyToken(id)
    }

    func unregister(_ token: HotkeyToken) {
        if let ref = refs.removeValue(forKey: token.id) { UnregisterEventHotKey(ref) }
        actions[token.id] = nil
        releases[token.id] = nil
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs = [:]
        actions = [:]
        releases = [:]
    }

    fileprivate func pressed(_ id: UInt32) {
        actions[id]?()
    }

    fileprivate func released(_ id: UInt32) {
        releases[id]?()
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var types = [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: $0)
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotkeyEvent, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else {
            Log.app.notice("hotkey handler not installed: OSStatus \(status)")
            return false
        }
        return true
    }
}

/// Carbon delivers hotkey events on the main thread's event loop.
private nonisolated func hotkeyEvent(_ call: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr else { return status }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
    let kind = GetEventKind(event)
    MainActor.assumeIsolated {
        if kind == UInt32(kEventHotKeyReleased) { center.released(id.id) } else { center.pressed(id.id) }
    }
    return noErr
}

extension Hotkey {
    static let commandModifier = UInt32(cmdKey)
    static let shiftModifier = UInt32(shiftKey)
    static let optionModifier = UInt32(optionKey)
    static let controlModifier = UInt32(controlKey)

    /// A hotkey from a key press, or nil when it has no ⌘, ⌃ or ⌥ to keep it from shadowing plain typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Self.commandModifier }
        if flags.contains(.shift) { modifiers |= Self.shiftModifier }
        if flags.contains(.option) { modifiers |= Self.optionModifier }
        if flags.contains(.control) { modifiers |= Self.controlModifier }
        guard modifiers & (Self.commandModifier | Self.optionModifier | Self.controlModifier) != 0 else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// The modifiers in the system's order, then the key as the current keyboard layout types it.
    var displayName: String {
        var name = ""
        if modifiers & Self.controlModifier != 0 { name += "⌃" }
        if modifiers & Self.optionModifier != 0 { name += "⌥" }
        if modifiers & Self.shiftModifier != 0 { name += "⇧" }
        if modifiers & Self.commandModifier != 0 { name += "⌘" }
        return name + Self.keyName(keyCode)
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "key \(keyCode)" }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
