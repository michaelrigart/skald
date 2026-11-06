import ApplicationServices

struct FocusDiagnosis: Sendable, Equatable {
    static let retryOffsetsMs = [0, 1000, 3000, 6000, 10000]

    var found: Bool
    var role: String?
    var errorCode: Int32

    static func take(pid: pid_t) -> FocusDiagnosis {
        let query = AXElement.focusedQuery(inApp: pid)
        return FocusDiagnosis(found: query.element != nil, role: query.element?.role, errorCode: query.error.rawValue)
    }

    /// A focus found late starts the session focusChanged would have started, unless the user has moved on.
    static func startsSession(found: Bool, frontmost: Bool, generationUnchanged: Bool) -> Bool {
        found && frontmost && generationUnchanged
    }

    func summary(afterMs: Int) -> String {
        "after \(afterMs) ms: element found \(found) role \(role ?? "-"), focused query AXError \(errorCode)"
    }
}
