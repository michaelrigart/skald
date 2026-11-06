#if DEBUG
import Foundation

struct ProbeLine: Codable, Equatable {
    var app: String
    var role: String
    var subrole: String
    var canRead = false
    var rangedRead = false
    var canReadSelection = false
    var canBound = false
    var boundsStable = false
    var canWrite = false
    var undoExact = false
    var undoEarlierHistory = false
    var formattingKept: Bool?
    var writeMethod: WriteMethod?
    var notifications: [String] = []
    var cpuIdle: Double?
    var cpuTyping: Double?
    var cpuIdleForced: Double?
    var cpuTypingForced: Double?

    static let secureRole = "AXSecureTextField"

    var isSecure: Bool { role == Self.secureRole || subrole == Self.secureRole }

    var cleanWrite: Bool {
        !isSecure && canWrite && undoExact && undoEarlierHistory && formattingKept != false
    }

    func render() -> String {
        let capabilities = isSecure
            ? Array(repeating: false, count: 8)
            : [canRead, rangedRead, canReadSelection, canBound, boundsStable, canWrite, undoExact, undoEarlierHistory]
        let columns: [String] = [app, Self.text(role), Self.text(subrole)]
            + capabilities.map { String($0) }
            + [
                isSecure ? "-" : formattingKept.map { String($0) } ?? "-",
                isSecure ? "-" : writeMethod?.rawValue ?? "-",
                isSecure || notifications.isEmpty ? "-" : notifications.joined(separator: ","),
                Self.percent(cpuIdle), Self.percent(cpuTyping),
                Self.percent(cpuIdleForced), Self.percent(cpuTypingForced),
            ]
        return columns.joined(separator: "\t")
    }

    private static func text(_ value: String) -> String { value.isEmpty ? "-" : value }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "-"
    }
}
#endif
