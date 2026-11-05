import ApplicationServices

struct FocusDiagnosis: Sendable, Equatable {
    var found: Bool
    var role: String?
    var errorCode: Int32

    static func take(pid: pid_t) -> FocusDiagnosis {
        let query = AXElement.focusedQuery(inApp: pid)
        return FocusDiagnosis(found: query.element != nil, role: query.element?.role, errorCode: query.error.rawValue)
    }

    func summary(afterMs: Int) -> String {
        "after \(afterMs) ms: element found \(found) role \(role ?? "-"), focused query AXError \(errorCode)"
    }
}
