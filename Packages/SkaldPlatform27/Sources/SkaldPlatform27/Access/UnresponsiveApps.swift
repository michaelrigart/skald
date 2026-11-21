import ApplicationServices

/// Apps that stopped answering Accessibility. Three snapshot or capture reads in a row that timed out mark an
/// app; a marked app is neither read nor captured until it is activated again, so Skald never retries it in a
/// loop. Kept on `AXQueue`.
struct UnresponsiveApps {
    static let timeoutsToMark = 3

    private var streaks: [String: Int] = [:]
    private var marked: Set<String> = []

    func isMarked(_ app: String) -> Bool {
        marked.contains(app)
    }

    /// Records one read; true when this read marks the app.
    mutating func read(_ app: String, timedOut: Bool) -> Bool {
        guard timedOut else {
            streaks[app] = nil
            return false
        }
        let streak = (streaks[app] ?? 0) + 1
        streaks[app] = streak
        return streak >= Self.timeoutsToMark && marked.insert(app).inserted
    }

    mutating func activated(_ app: String) {
        streaks[app] = nil
        marked.remove(app)
    }
}

/// Counts Accessibility calls that ended because the app didn't answer within the messaging timeout, on the
/// `AXQueue` they ran on: a reader compares the count before and after its own reads, which another queue's
/// timeouts must not move.
enum AXTimeouts {
    static var count: Int {
        AXQueue.timeouts
    }

    static func record(_ error: AXError) {
        if error == .cannotComplete { AXQueue.timedOut() }
    }
}
