import ApplicationServices
import Foundation

/// The focus query again with a longer messaging timeout: does a slow app answer when given time?
struct SlowFocusQuery: Sendable, Equatable {
    static let timeout: Float = 1

    var answered: Bool
    var found: Bool
    var errorCode: Int32
    var elapsedMs: Int

    var summary: String {
        "1 s timeout query answered \(answered), element found \(found), AXError \(errorCode), \(elapsedMs) ms"
    }
}

struct FocusDiagnosis: Sendable, Equatable {
    static let retryOffsetsMs = [0, 1000, 3000, 6000, 10000]
    static let cannotComplete = AXError.cannotComplete.rawValue

    var found: Bool
    var role: String?
    var errorCode: Int32
    var elapsedMs = 0
    var slow: SlowFocusQuery?

    static func take(pid: pid_t) -> FocusDiagnosis {
        let start = DispatchTime.now()
        let query = AXElement.focusedQuery(inApp: pid)
        var diagnosis = FocusDiagnosis(
            found: query.element != nil, role: query.element?.role, errorCode: query.error.rawValue, elapsedMs: milliseconds(since: start)
        )
        if needsSlowQuery(errorCode: diagnosis.errorCode, elapsedMs: diagnosis.elapsedMs) {
            let slowStart = DispatchTime.now()
            let slow = AXElement.focusedQuery(inApp: pid, timeout: SlowFocusQuery.timeout)
            diagnosis.slow = SlowFocusQuery(
                answered: slow.error != .cannotComplete, found: slow.element != nil, errorCode: slow.error.rawValue,
                elapsedMs: milliseconds(since: slowStart)
            )
        }
        return diagnosis
    }

    /// A query that could not complete, or that ran into the normal messaging timeout, is asked again with more time.
    static func needsSlowQuery(errorCode: Int32, elapsedMs: Int) -> Bool {
        errorCode == cannotComplete || elapsedMs >= Int(AXElement.messagingTimeout * 1000)
    }

    /// A focus found late starts the session focusChanged would have started, unless the user has moved on.
    static func startsSession(found: Bool, frontmost: Bool, generationUnchanged: Bool) -> Bool {
        found && frontmost && generationUnchanged
    }

    func summary(afterMs: Int) -> String {
        let base = "after \(afterMs) ms: element found \(found) role \(role ?? "-"), focused query AXError \(errorCode)"
        return slow.map { "\(base) in \(elapsedMs) ms; \($0.summary)" } ?? base
    }

    private static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
