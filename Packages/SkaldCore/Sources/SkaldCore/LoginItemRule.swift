/// The state of the login item, as `SMAppService.Status` reports it.
public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    /// Registered, but turned off by the user in System Settings > General > Login Items.
    case requiresApproval
    /// What macOS reports for a main app it has never seen, which is every app that was never registered.
    case notFound
}

public enum LoginItemAction: Equatable, Sendable {
    case register
    case unregister
    case none
}

public enum LoginItemRule {
    /// On launch, registers only an item that was never registered, so a choice made in System Settings stands. A
    /// change of the switch registers any item that is not enabled, and unregisters one that is enabled or waiting
    /// for approval.
    public static func action(enabled: Bool, status: LoginItemStatus, changed: Bool) -> LoginItemAction {
        if enabled {
            if changed { return status == .enabled ? .none : .register }
            return status == .notRegistered || status == .notFound ? .register : .none
        }
        return changed && (status == .enabled || status == .requiresApproval) ? .unregister : .none
    }
}
