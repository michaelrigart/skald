import Foundation

struct FieldObservation {
    static let notificationWindow: Duration = .seconds(2)
    static let trackedNotifications: Set<String> = [
        "AXValueChanged", "AXSelectedTextChanged", "AXFocusedUIElementChanged",
    ]

    var line: ProbeLine
    var identity: String
    var hasFrame = false
    var baseline: BoundsBaseline?
    var undoPresses = 0

    private var notifications: Set<String> = []
    private var write: WriteStart?
    private var writeAborted = false
    private var writeInFlight = false
    private var typedSinceUndo = false
    private var movedChecks = 0
    private var failedChecks = 0

    init(app: String, reading: FieldReading) {
        line = ProbeLine(app: app, role: reading.role, subrole: reading.subrole)
        identity = reading.identity
        absorb(reading)
    }

    var formatting: (location: Int, length: Int)? {
        guard let write, !line.canWrite, write.beforeLength > 0 else { return nil }
        return (write.beforeLocation, write.beforeLength)
    }

    func shouldWrite(for reading: FieldReading) -> Bool {
        guard awaitingWrite, let value = reading.value else { return false }
        return ProbeMarker.range(in: value, caret: reading.selection) != nil
    }

    var awaitingWrite: Bool { !line.isSecure && write == nil && !writeAborted && !writeInFlight }

    /// How a value compares with the written and the original text, in lengths and booleans only.
    func writeCheck(_ value: String) -> String? {
        guard let write else { return nil }
        let length = (value as NSString).length
        return "value \(length) units (written \((write.expectedAfterWrite as NSString).length), original \((write.original as NSString).length)); "
            + "is written \(value == write.expectedAfterWrite), is original \(value == write.original), "
            + "has ok marker \(value.contains(ProbeMarker.replacement)), has probe marker \(value.contains(ProbeMarker.pending)), undo presses \(undoPresses)"
    }

    var finishedLine: ProbeLine {
        var finished = line
        finished.notifications = notifications.sorted()
        return finished
    }

    mutating func recordWrite(_ start: WriteStart) {
        write = start
        line.writeMethod = start.method
        undoPresses = 0
        typedSinceUndo = false
    }

    mutating func beginWrite() {
        writeInFlight = true
    }

    mutating func endWrite() {
        writeInFlight = false
    }

    mutating func recordWriteAborted() {
        writeAborted = true
    }

    mutating func recordUndo() {
        guard write != nil else { return }
        undoPresses += 1
        typedSinceUndo = false
    }

    mutating func recordTyping() {
        guard write != nil else { return }
        typedSinceUndo = true
    }

    mutating func record(notification name: String, afterKeystroke: Bool) {
        guard afterKeystroke, !line.isSecure, Self.trackedNotifications.contains(name) else { return }
        notifications.insert(name)
    }

    mutating func recordBoundsCheck(_ kind: RecheckKind, stable: Bool, baseline updated: BoundsBaseline?) {
        if !stable { failedChecks += 1 }
        if kind == .windowMoved { movedChecks += 1 }
        line.boundsStable = movedChecks > 0 && failedChecks == 0
        if let updated { baseline = updated }
    }

    mutating func absorb(_ reading: FieldReading) {
        line.role = reading.role
        line.subrole = reading.subrole
        guard !line.isSecure else { return }
        identity = reading.identity
        line.canRead = line.canRead || reading.canRead
        line.rangedRead = line.rangedRead || reading.rangedRead
        line.canReadSelection = line.canReadSelection || reading.canReadSelection
        hasFrame = hasFrame || reading.hasFrame
        if let found = reading.baseline {
            baseline = found
            line.canBound = true
        }
        guard let write, let value = reading.value else { return }

        if !line.canWrite, value == write.expectedAfterWrite {
            line.canWrite = true
            line.formattingKept = Self.formattingKept(before: write.before, after: reading.formatted)
        }
        guard line.canWrite else { return }
        if undoPresses >= 1, !line.undoExact, value == write.original {
            line.undoExact = true
        }
        if undoPresses >= 2, line.undoExact, !typedSinceUndo, value != write.original {
            line.undoEarlierHistory = true
        }
    }

    private static func formattingKept(before: AttributedSnapshot?, after: AttributedSnapshot?) -> Bool? {
        guard let before, let after else { return nil }
        return FormattingFingerprint.kept(before: before.value, after: after.value)
    }
}
