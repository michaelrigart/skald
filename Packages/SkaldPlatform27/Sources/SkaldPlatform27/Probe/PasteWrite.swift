import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct PasteOutcome: Sendable {
    var selectionWaitedMs: Int
    var posted: Bool
    var valueChangedAfterMs: Int?
    var finalValue: String?
}

struct PasteRecheck: Sendable {
    var targetIsFrontmost: Bool
    var sameField: Bool
    var selectionOnMarker: Bool

    var failure: String? {
        if !targetIsFrontmost { return "the target app is no longer frontmost" }
        if !sameField { return "the focused element changed" }
        if !selectionOnMarker { return "the selection left the marker" }
        return nil
    }
}

enum PasteWrite {
    static let timeoutMs = 3000
    static let pollMs = 25
    static let settleMs = 200
    static let layoutDependentVKeyCode = CGKeyCode(kVK_ANSI_V)

    /// Callers must have staged the pasteboard and re-checked the selection immediately before.
    static func send(to pid: pid_t, field: AXElement, original: String, selectionWaitedMs: Int) -> PasteOutcome {
        let posted = postCommandV(to: pid)
        var changedAfter: Int?
        if posted {
            changedAfter = waitForChange(of: field, from: original)
            usleep(useconds_t(settleMs * 1000))
        }
        return PasteOutcome(
            selectionWaitedMs: selectionWaitedMs, posted: posted, valueChangedAfterMs: changedAfter, finalValue: field.value
        )
    }

    static func describe(_ outcome: PasteOutcome) -> String {
        if !outcome.posted { return "key events could not be created" }
        if let changed = outcome.valueChangedAfterMs { return "value changed after \(changed) ms" }
        return "value unchanged after \(timeoutMs) ms"
    }

    static func describe(_ restoration: PasteboardSwap.Restoration) -> String {
        restoration == .restored ? "pasteboard restored" : "pasteboard left alone (changed by another app)"
    }

    private static func postCommandV(to pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: layoutDependentVKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: layoutDependentVKeyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private static func waitForChange(of field: AXElement, from original: String) -> Int? {
        var waited = 0
        while true {
            if let value = field.value, value != original { return waited }
            guard waited < timeoutMs else { return nil }
            usleep(useconds_t(pollMs * 1000))
            waited += pollMs
        }
    }
}
