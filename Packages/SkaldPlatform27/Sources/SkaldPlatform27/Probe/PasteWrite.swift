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
    var sameField: Bool
    var targetIsFrontmost: Bool
    var selectionOnMarker: Bool

    var failure: String? {
        if !sameField { return "the focused element changed" }
        if !targetIsFrontmost { return "the target app is no longer frontmost" }
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
    static func send(to pid: pid_t, field: AXElement, kind: FieldKind, original: String, selectionWaitedMs: Int) -> PasteOutcome {
        let posted = postCommandV(to: pid)
        var changedAfter: Int?
        if posted {
            changedAfter = waitForChange(of: field, kind: kind, from: original)
            usleep(useconds_t(settleMs * 1000))
        }
        return PasteOutcome(
            selectionWaitedMs: selectionWaitedMs, posted: posted, valueChangedAfterMs: changedAfter, finalValue: FieldProbe.text(of: field, kind: kind)
        )
    }

    static func describe(_ outcome: PasteOutcome) -> String {
        if !outcome.posted { return "key events could not be created" }
        if let changed = outcome.valueChangedAfterMs { return "value changed after \(changed) ms" }
        return "value unchanged after \(timeoutMs) ms"
    }

    /// What the probe does with the clipboard once ⌘V was posted.
    enum Clipboard: Equatable {
        case restore
        /// The field doesn't show the expected value: a late paste would insert whatever the clipboard holds.
        case keepMarker
    }

    static let unconfirmed = "paste unconfirmed; clipboard holds the probe marker"

    /// Nothing posted means nothing can paste; otherwise only the expected value proves the app consumed the paste.
    static func clipboard(after outcome: PasteOutcome, expected: String) -> Clipboard {
        !outcome.posted || outcome.finalValue == expected ? .restore : .keepMarker
    }

    static func describe(_ restoration: PasteboardSwap.Restoration) -> String {
        restoration == .restored ? "pasteboard restored" : "pasteboard left alone (changed by another app)"
    }

    private static func postCommandV(to pid: pid_t) -> Bool {
        CommandV.post(to: pid, keyCode: layoutDependentVKeyCode)
    }

    private static func waitForChange(of field: AXElement, kind: FieldKind, from original: String) -> Int? {
        var waited = 0
        while true {
            if let value = FieldProbe.text(of: field, kind: kind), value != original { return waited }
            guard waited < timeoutMs else { return nil }
            usleep(useconds_t(pollMs * 1000))
            waited += pollMs
        }
    }
}
