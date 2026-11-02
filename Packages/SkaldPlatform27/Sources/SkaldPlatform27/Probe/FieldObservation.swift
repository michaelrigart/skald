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
    private var boundsChecks: [Bool] = []

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
        !line.isSecure && write == nil && reading.value?.hasSuffix(ProbeMarker.pending) == true
    }

    var finishedLine: ProbeLine {
        var finished = line
        finished.notifications = notifications.sorted()
        return finished
    }

    mutating func recordWrite(_ start: WriteStart) {
        write = start
    }

    mutating func recordUndo() {
        undoPresses += 1
    }

    mutating func record(notification name: String, afterKeystroke: Bool) {
        guard afterKeystroke, !line.isSecure, Self.trackedNotifications.contains(name) else { return }
        notifications.insert(name)
    }

    mutating func recordBoundsCheck(stable: Bool, baseline updated: BoundsBaseline?) {
        boundsChecks.append(stable)
        line.boundsStable = boundsChecks.allSatisfy { $0 }
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

        if !line.canWrite, value.hasSuffix(ProbeMarker.replacement) {
            line.canWrite = true
            line.formattingKept = Self.formattingKept(before: write.before, after: reading.formatted)
        }
        guard line.canWrite else { return }
        if undoPresses >= 1, !line.undoExact, value == write.original {
            line.undoExact = true
        }
        if undoPresses >= 2, line.undoExact, !line.undoEarlierHistory, !value.contains(ProbeMarker.earlierWord) {
            line.undoEarlierHistory = true
        }
    }

    private static func formattingKept(before: AttributedSnapshot?, after: AttributedSnapshot?) -> Bool? {
        guard let before, let after else { return nil }
        return before.value.isEqual(to: after.value)
    }
}
