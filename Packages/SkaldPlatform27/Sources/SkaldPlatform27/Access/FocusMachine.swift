import Foundation
import SkaldCore

/// The observer's focus decisions, free of Accessibility calls: the generation, the frontmost app, the
/// current field, repeat suppression, and when retries start or stop.
struct FocusMachine {
    enum Query: Sendable, Equatable {
        case activation, focusChange, retry
    }

    enum QueryResult: Sendable, Equatable {
        /// The app gave no focused element.
        case missing
        /// A focused element, and its field when it is one.
        case element(FieldID?)
    }

    enum Step: Sendable, Equatable {
        case cancelRetries
        /// Drop the current app observer, then observe `pid` (nil: nothing).
        case observe(pid: pid_t?, app: String?)
        /// Register the app's focus notification if it isn't yet (Accessibility may have been granted since).
        case ensureObserved(pid: pid_t, app: String)
        case query(pid: pid_t, app: String, Query)
        case startRetries(generation: Int, pid: pid_t, app: String)
        /// Watch the field's value and selection notifications (nil: none).
        case watch(FieldID?)
        case emit(FieldEvent)
    }

    let ownPID: pid_t
    private(set) var generation = 0
    private(set) var frontPID: pid_t?
    private(set) var frontApp: String?
    /// The frontmost app is observed: not Skald, and on in the app switches when it activated.
    private(set) var frontObserved = false
    private(set) var current: FieldID?

    init(ownPID: pid_t) {
        self.ownPID = ownPID
    }

    mutating func activated(pid: pid_t, app: String, enabled: Bool) -> [Step] {
        generation += 1
        frontPID = pid
        frontApp = app
        frontObserved = pid != ownPID && enabled
        guard frontObserved else { return [.cancelRetries, .observe(pid: nil, app: nil)] + settle(nil) }
        return [.cancelRetries, .observe(pid: pid, app: app), .query(pid: pid, app: app, .activation)]
    }

    /// Accessibility was granted after launch: the frontmost app is observed and asked again, as on activation.
    mutating func reactivated(isEnabled: (String) -> Bool) -> [Step] {
        guard let frontPID, let frontApp else { return [] }
        return activated(pid: frontPID, app: frontApp, enabled: isEnabled(frontApp))
    }

    /// The app switches changed: the frontmost app is dropped or observed only when its own switch flipped.
    mutating func switchesChanged(isEnabled: (String) -> Bool) -> [Step] {
        guard let frontPID, let frontApp, frontPID != ownPID, isEnabled(frontApp) != frontObserved else { return [] }
        return activated(pid: frontPID, app: frontApp, enabled: isEnabled(frontApp))
    }

    mutating func focusChanged(pid: pid_t) -> [Step] {
        guard pid == frontPID, let frontApp else { return [] }
        generation += 1
        return [.cancelRetries, .query(pid: pid, app: frontApp, .focusChange)]
    }

    func fieldChanged(pid: pid_t, value: Bool) -> [Step] {
        guard pid == frontPID, let current else { return [] }
        return [.emit(value ? .edited(current) : .caretMoved(current))]
    }

    /// A retry still counts only while neither focus nor the frontmost app changed since it was started.
    func retryTick(generation started: Int, pid: pid_t) -> Bool {
        started == generation && pid == frontPID
    }

    mutating func queried(_ query: Query, _ result: QueryResult) -> [Step] {
        switch result {
        case .element(let field):
            guard query == .retry, let frontPID, let frontApp else { return settle(field) }
            return [.ensureObserved(pid: frontPID, app: frontApp)] + settle(field)
        case .missing:
            guard query == .activation, let frontPID, let frontApp else { return settle(nil) }
            return settle(nil) + [.startRetries(generation: generation, pid: frontPID, app: frontApp)]
        }
    }

    /// The same field focused again is no event: a focus event cancels the running checks.
    private mutating func settle(_ field: FieldID?) -> [Step] {
        let repeated = field != nil && field == current
        current = field
        return repeated ? [.watch(field)] : [.watch(field), .emit(.focused(field))]
    }
}

/// The Accessibility side of the focus machine's steps.
protocol FocusPort: AnyObject {
    func observe(pid: pid_t?, app: String?)
    func ensureObserved(pid: pid_t, app: String)
    func queryFocus(pid: pid_t, app: String) -> FocusMachine.QueryResult
    func watch(_ field: FieldID?)
    func emit(_ event: FieldEvent)
}

/// Feeds inputs to the focus machine and carries out its steps through the port, with retries on the clock.
final class FocusDriver: @unchecked Sendable { // reason: state is touched only inside bodies run by `hop` (AXQueue in the app)
    typealias Hop = @Sendable (@escaping @Sendable () -> FocusAttempt) async -> FocusAttempt

    weak var port: (any FocusPort)?
    private var machine: FocusMachine
    private let retries: FocusRetries
    private let hop: Hop

    init(ownPID: pid_t, clock: any Clock<Duration>, hop: @escaping Hop) {
        machine = FocusMachine(ownPID: ownPID)
        retries = FocusRetries(clock: clock)
        self.hop = hop
    }

    var current: FieldID? { machine.current }

    func activated(pid: pid_t, app: String, enabled: Bool) {
        run(machine.activated(pid: pid, app: app, enabled: enabled))
    }

    func focusChanged(pid: pid_t) {
        run(machine.focusChanged(pid: pid))
    }

    func reactivated(isEnabled: (String) -> Bool) {
        run(machine.reactivated(isEnabled: isEnabled))
    }

    func switchesChanged(isEnabled: (String) -> Bool) {
        run(machine.switchesChanged(isEnabled: isEnabled))
    }

    func fieldChanged(pid: pid_t, value: Bool) {
        run(machine.fieldChanged(pid: pid, value: value))
    }

    func stop() {
        retries.cancel()
    }

    private func run(_ steps: [FocusMachine.Step]) {
        for step in steps {
            switch step {
            case .cancelRetries:
                retries.cancel()
            case let .observe(pid, app):
                port?.observe(pid: pid, app: app)
            case let .ensureObserved(pid, app):
                port?.ensureObserved(pid: pid, app: app)
            case let .query(pid, app, query):
                guard let port else { return }
                run(machine.queried(query, port.queryFocus(pid: pid, app: app)))
            case let .startRetries(generation, pid, app):
                PlatformLog.access.notice("no focused element at activation: \(app, privacy: .public)")
                retries.start { [weak self, hop] in
                    guard let driver = self else { return .moved }
                    return await hop { driver.tick(generation: generation, pid: pid, app: app) }
                }
            case let .watch(field):
                port?.watch(field)
            case let .emit(event):
                port?.emit(event)
            }
        }
    }

    private func tick(generation: Int, pid: pid_t, app: String) -> FocusAttempt {
        guard machine.retryTick(generation: generation, pid: pid), let port else { return .moved }
        let result = port.queryFocus(pid: pid, app: app)
        guard result != .missing else { return .missing }
        PlatformLog.access.notice("focused element appeared on a retry: \(app, privacy: .public)")
        run(machine.queried(.retry, result))
        return .found
    }
}
