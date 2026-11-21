import AppKit
import ApplicationServices
import SkaldCore

/// Asks again for the focused element at 1, 3, 6 and 10 s after activation, until it appears or focus moves.
final class FocusRetries: @unchecked Sendable { // reason: the pending task is only touched under the lock
    private let timer: @Sendable () -> @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var pending: Task<Void, Never>?

    init<C: Clock<Duration>>(clock: C) {
        timer = {
            let origin = clock.now
            return { try await clock.sleep(until: origin.advanced(by: $0), tolerance: nil) }
        }
    }

    /// Replaces any pending retries. The activation's own query was the first attempt and found nothing.
    @discardableResult
    func start(_ attempt: @escaping @Sendable () async -> FocusAttempt) -> Task<Void, Never> {
        let sleep = timer()
        let task = Task {
            var attempts = 1
            var outcome = FocusAttempt.missing
            while let offset = TextAccessRules.nextFocusRetry(afterAttempts: attempts, outcome: outcome) {
                do { try await sleep(offset) } catch { return }
                attempts += 1
                outcome = await attempt()
            }
        }
        lock.withLock {
            pending?.cancel()
            pending = task
        }
        return task
    }

    func cancel() {
        lock.withLock {
            pending?.cancel()
            pending = nil
        }
    }
}

private final class ObserverContext: Sendable {
    weak let observer: FieldObserver?
    let pid: pid_t

    init(observer: FieldObserver, pid: pid_t) {
        self.observer = observer
        self.pid = pid
    }
}

private func deliver(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    context.observer?.received(notification as String, pid: context.pid)
}

/// What a notification from the observed app means.
enum ObservedNotification: Equatable {
    case focus, value, selection
    /// One of the app's windows moved or changed size, so the field may have moved on screen.
    case windowGeometry

    init?(_ name: String) {
        switch name {
        case kAXFocusedUIElementChangedNotification: self = .focus
        case kAXValueChangedNotification: self = .value
        case kAXSelectedTextChangedNotification: self = .selection
        case kAXWindowMovedNotification, kAXWindowResizedNotification: self = .windowGeometry
        default: return nil
        }
    }
}

/// The notifications a session registers on the application element, and which of them it has. A failed
/// registration is tried again whenever the session is asked to make sure it observes the app.
struct ApplicationRegistrations {
    static let all = [kAXFocusedUIElementChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification]

    private(set) var registered: Set<String> = []

    var missing: [String] { Self.all.filter { !registered.contains($0) } }

    mutating func register(_ add: (String) -> Bool) {
        for name in missing where add(name) { registered.insert(name) }
    }
}

/// One AXObserver on the frontmost app: focus changes and window moves and resizes on the app, value and
/// selection changes on its focused field.
private final class ObserverSession {
    private static let fieldNotifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]

    let pid: pid_t
    private let app: String
    private let observer: AXObserver
    private let refcon: UnsafeMutableRawPointer
    private var field: AXElement?
    private var registrations = ApplicationRegistrations()

    init?(pid: pid_t, app: String, refcon: UnsafeMutableRawPointer) {
        var created: AXObserver?
        let error = AXObserverCreate(pid, deliver, &created)
        guard error == .success, let created else {
            PlatformLog.access.notice("observer not created: \(app, privacy: .public): AXError \(error.rawValue)")
            return nil
        }
        self.pid = pid
        self.app = app
        self.refcon = refcon
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        registerOnApplication()
    }

    /// Registers what is still missing: focus changes, and moves and resizes of the app's windows.
    func registerOnApplication() {
        let app = AXElement.application(pid: pid)
        registrations.register { add($0, to: app) }
    }

    func watch(_ element: AXElement?) {
        if let field {
            Self.fieldNotifications.forEach { AXObserverRemoveNotification(observer, field.element, $0 as CFString) }
        }
        field = element
        guard let element else { return }
        Self.fieldNotifications.forEach { _ = add($0, to: element) }
    }

    func detach() {
        watch(nil)
        let app = AXElement.application(pid: pid).element
        ApplicationRegistrations.all.forEach { AXObserverRemoveNotification(observer, app, $0 as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func add(_ notification: String, to element: AXElement) -> Bool {
        let error = AXObserverAddNotification(observer, element.element, notification as CFString, refcon)
        guard error == .success || error == .notificationAlreadyRegistered else {
            PlatformLog.access.notice("notification not registered: \(self.app, privacy: .public): \(notification, privacy: .public): AXError \(error.rawValue)")
            return false
        }
        return true
    }
}

/// The Accessibility side of the frontmost app's focus: the focus machine decides, this makes the calls.
/// It turns notifications into `FieldEvent`s, and window moves and resizes into `moved`, without reading any text.
final class FieldObserver: FocusPort, @unchecked Sendable { // reason: state is touched only inside AXQueue closures, the token only in init and deinit
    typealias Registry = FieldRegistry<AXElement, any FieldReader>

    private let queue: AXQueue
    private let driver: FocusDriver
    private let isAppEnabled: @Sendable (String) -> Bool
    private let send: @Sendable (FieldEvent) -> Void
    private let moved: @Sendable () -> Void

    private var activation: NSObjectProtocol?
    private var registry = Registry(isSame: { $0.isSame(as: $1) }) {
        TextAccessRules.isFieldCandidate(role: $0.role, subrole: $0.subrole, appEnabled: true)
    }
    private var session: ObserverSession?
    /// Contexts live as long as the observer, so a callback already running never sees a freed one.
    private var contexts: [pid_t: ObserverContext] = [:]
    private var enablement = AccessibilityEnablement()
    private var unresponsive = UnresponsiveApps()

    init(
        queue: AXQueue, clock: any Clock<Duration>, isAppEnabled: @escaping @Sendable (String) -> Bool,
        moved: @escaping @Sendable () -> Void, emit: @escaping @Sendable (FieldEvent) -> Void
    ) {
        self.queue = queue
        driver = FocusDriver(ownPID: ProcessInfo.processInfo.processIdentifier, clock: clock) { body in await queue.run(body) }
        self.isAppEnabled = isAppEnabled
        self.moved = moved
        send = emit
        driver.port = self
    }

    deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        driver.stop()
        session?.detach()
    }

    func start() {
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activated(pid: app.processIdentifier, app: app.bundleIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            activated(pid: app.processIdentifier, app: app.bundleIdentifier)
        }
    }

    func received(_ notification: String, pid: pid_t) {
        queue.enqueue { [self] in
            switch ObservedNotification(notification) {
            case .focus: driver.focusChanged(pid: pid)
            case .value: driver.fieldChanged(pid: pid, value: true)
            case .selection: driver.fieldChanged(pid: pid, value: false)
            case .windowGeometry: moved()
            case nil: break
            }
        }
    }

    /// Observes the frontmost app again and asks for its focus, as when it activated.
    func reactivate() {
        queue.enqueue { [self] in driver.reactivated(isEnabled: isAppEnabled) }
    }

    /// Drops the frontmost app when it was turned off, or observes it when it was turned on.
    func switchesChanged() {
        queue.enqueue { [self] in driver.switchesChanged(isEnabled: isAppEnabled) }
    }

    private func activated(pid: pid_t, app: String?) {
        let app = app ?? "unknown"
        queue.enqueue { [self] in
            unresponsive.activated(app)
            driver.activated(pid: pid, app: app, enabled: isAppEnabled(app))
        }
    }

    // MARK: On AXQueue only

    func entry(_ id: FieldID) -> Registry.Entry? {
        registry.entry(id)
    }

    /// A snapshot or capture read of `app`'s field, skipped while the app is marked unresponsive. Its third
    /// timed-out read in a row marks it, logged once.
    func read<T>(app: String, _ body: () -> T?) -> T? {
        guard !unresponsive.isMarked(app) else { return nil }
        let before = AXTimeouts.count
        let result = body()
        if unresponsive.read(app, timedOut: AXTimeouts.count > before) {
            PlatformLog.access.notice("unresponsive: \(app, privacy: .public): \(UnresponsiveApps.timeoutsToMark) reads in a row timed out, skipped until it is activated again")
        }
        return result
    }

    func newest(app: String) -> Registry.Entry? {
        registry.newest(app: app)
    }

    /// The field the observer last saw focused, while it is still the focused element of the focused app.
    func focusedField() -> FieldID? {
        guard let id = driver.current, let entry = registry.entry(id), isFocused(entry) else { return nil }
        return id
    }

    /// Asked live: the field is the focused element of the system's focused app, resolved as at registration.
    func isFocused(_ entry: Registry.Entry) -> Bool {
        guard let pid = entry.element.pid, AXElement.focusedApplicationPID() == pid else { return false }
        return isFocusedElement(entry, pid: pid)
    }

    /// The app's focused element, resolved through `EditableResolver`, is the field.
    func isFocusedElement(_ entry: Registry.Entry, pid: pid_t) -> Bool {
        guard let focused = AXElement.focused(inApp: pid), let field = EditableResolver.field(for: focused) else { return false }
        return field.isSame(as: entry.element)
    }

    // MARK: FocusPort

    func observe(pid: pid_t?, app: String?) {
        session?.detach()
        session = nil
        guard let pid, let app else { return }
        let mode = CapabilityTable.access(for: app).mode
        let enableAttribute = { (attribute: String) in
            AXUIElementSetAttributeValue(AXElement.application(pid: pid).element, attribute as CFString, kCFBooleanTrue)
        }
        if let results = enablement.enable(pid: pid, mode: mode, using: enableAttribute) {
            PlatformLog.access.notice("accessibility enabled: \(app, privacy: .public): \(results.map(\.summary).joined(separator: ", "), privacy: .public)")
        }
        session = ObserverSession(pid: pid, app: app, refcon: Unmanaged.passUnretained(context(for: pid)).toOpaque())
    }

    func ensureObserved(pid: pid_t, app: String) {
        guard let session, session.pid == pid else { return observe(pid: pid, app: app) }
        session.registerOnApplication()
    }

    func queryFocus(pid: pid_t, app: String) -> FocusMachine.QueryResult {
        guard let focused = AXElement.focused(inApp: pid) else { return .missing }
        guard isAppEnabled(app), let element = EditableResolver.field(for: focused) else { return .element(nil) }
        let candidate = TextAccessRules.isFieldCandidate(role: element.role, subrole: element.subrole, appEnabled: true)
        return .element(registry.focus(element, app: app, isCandidate: candidate, source: { FieldSource.reader(for: element) }))
    }

    func watch(_ field: FieldID?) {
        session?.watch(field.flatMap { registry.entry($0)?.element })
    }

    func emit(_ event: FieldEvent) {
        send(event)
    }

    private func context(for pid: pid_t) -> ObserverContext {
        if let context = contexts[pid] { return context }
        let context = ObserverContext(observer: self, pid: pid)
        contexts[pid] = context
        return context
    }
}
