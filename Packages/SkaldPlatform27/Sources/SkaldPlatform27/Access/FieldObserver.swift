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

/// One AXObserver on the frontmost app: focus changes on the app, value and selection changes on its focused field.
private final class ObserverSession {
    private static let fieldNotifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]

    let pid: pid_t
    private let app: String
    private let observer: AXObserver
    private let refcon: UnsafeMutableRawPointer
    private var field: AXElement?
    private(set) var focusRegistered = false

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
        registerFocus()
    }

    func registerFocus() {
        guard !focusRegistered else { return }
        focusRegistered = add(kAXFocusedUIElementChangedNotification, to: AXElement.application(pid: pid))
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
        AXObserverRemoveNotification(observer, AXElement.application(pid: pid).element, kAXFocusedUIElementChangedNotification as CFString)
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
/// It turns notifications into `FieldEvent`s without reading any text.
final class FieldObserver: FocusPort, @unchecked Sendable { // reason: state is touched only inside AXQueue closures, the token only in init and deinit
    typealias Registry = FieldRegistry<AXElement, any FieldReader>

    private let queue: AXQueue
    private let driver: FocusDriver
    private let isAppEnabled: @Sendable (String) -> Bool
    private let send: @Sendable (FieldEvent) -> Void

    private var activation: NSObjectProtocol?
    private var registry = Registry(isSame: { $0.isSame(as: $1) })
    private var session: ObserverSession?
    /// Contexts live as long as the observer, so a callback already running never sees a freed one.
    private var contexts: [pid_t: ObserverContext] = [:]
    private var enabledPIDs: Set<pid_t> = []

    init(
        queue: AXQueue, clock: any Clock<Duration>, isAppEnabled: @escaping @Sendable (String) -> Bool,
        emit: @escaping @Sendable (FieldEvent) -> Void
    ) {
        self.queue = queue
        driver = FocusDriver(ownPID: ProcessInfo.processInfo.processIdentifier, clock: clock) { body in await queue.run(body) }
        self.isAppEnabled = isAppEnabled
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
            switch notification {
            case kAXFocusedUIElementChangedNotification: driver.focusChanged(pid: pid)
            case kAXValueChangedNotification: driver.fieldChanged(pid: pid, value: true)
            case kAXSelectedTextChangedNotification: driver.fieldChanged(pid: pid, value: false)
            default: break
            }
        }
    }

    private func activated(pid: pid_t, app: String?) {
        let app = app ?? "unknown"
        queue.enqueue { [self] in driver.activated(pid: pid, app: app, enabled: isAppEnabled(app)) }
    }

    // MARK: On AXQueue only

    func entry(_ id: FieldID) -> Registry.Entry? {
        registry.entry(id)
    }

    func newest(app: String) -> Registry.Entry? {
        registry.newest(app: app)
    }

    /// Asked live: the field is the focused element of the system's focused app.
    func isFocused(_ entry: Registry.Entry) -> Bool {
        guard let pid = entry.element.pid, AXElement.focusedApplicationPID() == pid,
              let focused = AXElement.focused(inApp: pid)
        else { return false }
        return focused.isSame(as: entry.element)
    }

    // MARK: FocusPort

    func observe(pid: pid_t?, app: String?) {
        session?.detach()
        session = nil
        guard let pid, let app else { return }
        let mode = CapabilityTable.access(for: app).mode
        if mode != .native, enabledPIDs.insert(pid).inserted {
            let results = mode.enable(on: AXElement.application(pid: pid).element)
            PlatformLog.access.notice("accessibility enabled: \(app, privacy: .public): \(results.map(\.summary).joined(separator: ", "), privacy: .public)")
        }
        session = ObserverSession(pid: pid, app: app, refcon: Unmanaged.passUnretained(context(for: pid)).toOpaque())
    }

    func ensureObserved(pid: pid_t, app: String) {
        guard let session, session.pid == pid else { return observe(pid: pid, app: app) }
        session.registerFocus()
    }

    func queryFocus(pid: pid_t, app: String) -> FocusMachine.QueryResult {
        guard let element = AXElement.focused(inApp: pid) else { return .missing }
        let candidate = TextAccessRules.isFieldCandidate(role: element.role, subrole: element.subrole, appEnabled: isAppEnabled(app))
        return .element(registry.focus(element, app: app, isCandidate: candidate, source: { RangeReader(element) }))
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
