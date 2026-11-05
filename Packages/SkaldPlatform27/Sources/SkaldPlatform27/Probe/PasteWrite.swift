import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum PasteWrite {
    static let timeoutMs = 1000
    static let pollMs = 25
    static let settleMs = 200
    static let layoutDependentVKeyCode = CGKeyCode(kVK_ANSI_V)

    struct Outcome {
        var posted: Bool
        var valueChangedAfterMs: Int?
        var restoration: PasteboardSwap.Restoration
    }

    /// Callers must have verified that the selection is on the marker before calling.
    static func send(to pid: pid_t, field: AXElement, original: String) -> Outcome {
        let swap = PasteboardSwap()
        swap.stage(ProbeMarker.replacement)
        let posted = postCommandV(to: pid)
        var changedAfter: Int?
        if posted {
            changedAfter = waitForChange(of: field, from: original)
            usleep(useconds_t(settleMs * 1000))
        }
        return Outcome(posted: posted, valueChangedAfterMs: changedAfter, restoration: swap.restore())
    }

    static func describe(_ outcome: Outcome) -> String {
        let value: String
        if !outcome.posted {
            value = "key events could not be created"
        } else if let changed = outcome.valueChangedAfterMs {
            value = "value changed after \(changed) ms"
        } else {
            value = "value unchanged after \(timeoutMs) ms"
        }
        let pasteboard = outcome.restoration == .restored
            ? "pasteboard restored" : "pasteboard left alone (changed by another app)"
        return "\(value), \(pasteboard)"
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
