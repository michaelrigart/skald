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
    private let observer: AXObserver
    private let refcon: UnsafeMutableRawPointer
    private var field: AXElement?

    init?(pid: pid_t, refcon: UnsafeMutableRawPointer) {
        var created: AXObserver?
        guard AXObserverCreate(pid, deliver, &created) == .success, let created else { return nil }
        self.pid = pid
        self.refcon = refcon
        observer = created
        AXObserverAddNotification(created, AXElement.application(pid: pid).element, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    func watch(_ element: AXElement?) {
        if let field {
            Self.fieldNotifications.forEach { AXObserverRemoveNotification(observer, field.element, $0 as CFString) }
        }
        field = element
        guard let element else { return }
        Self.fieldNotifications.forEach { AXObserverAddNotification(observer, element.element, $0 as CFString, refcon) }
    }

    func detach() {
        watch(nil)
        AXObserverRemoveNotification(observer, AXElement.application(pid: pid).element, kAXFocusedUIElementChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

/// Turns the frontmost app's Accessibility notifications into `FieldEvent`s without reading any text.
final class FieldObserver: @unchecked Sendable { // reason: state is touched only inside AXQueue closures, the token only in init and deinit
    typealias Registry = FieldRegistry<AXElement, any FieldReader>

    private let queue: AXQueue
    private let retries: FocusRetries
    private let isAppEnabled: @Sendable (String) -> Bool
    private let emit: @Sendable (FieldEvent) -> Void
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var activation: NSObjectProtocol?
    private var registry = Registry(isSame: { $0.isSame(as: $1) })
    private var front: (pid: pid_t, app: String)?
    private var session: ObserverSession?
    /// Contexts live as long as the observer, so a callback already running never sees a freed one.
    private var contexts: [pid_t: ObserverContext] = [:]
    private var enabledPIDs: Set<pid_t> = []
    private var current: (id: FieldID, element: AXElement)?
    private var generation = 0

    init(
        queue: AXQueue, clock: any Clock<Duration>, isAppEnabled: @escaping @Sendable (String) -> Bool,
        emit: @escaping @Sendable (FieldEvent) -> Void
    ) {
        self.queue = queue
        retries = FocusRetries(clock: clock)
        self.isAppEnabled = isAppEnabled
        self.emit = emit
    }

    deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        retries.cancel()
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
        queue.enqueue { [self] in handle(notification, pid: pid) }
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

    private func activated(pid: pid_t, app: String?) {
        queue.enqueue { [self] in activate(pid: pid, app: app ?? "unknown") }
    }

    private func activate(pid: pid_t, app: String) {
        generation += 1
        retries.cancel()
        session?.detach()
        session = nil
        front = (pid, app)
        guard pid != ownPID, isAppEnabled(app) else {
            setCurrent(nil)
            return
        }
        let mode = CapabilityTable.access(for: app).mode
        if mode != .native, enabledPIDs.insert(pid).inserted {
            let results = mode.enable(on: AXElement.application(pid: pid).element)
            PlatformLog.access.notice("accessibility enabled: \(app, privacy: .public): \(results.map(\.summary).joined(separator: ", "), privacy: .public)")
        }
        session = ObserverSession(pid: pid, refcon: Unmanaged.passUnretained(context(for: pid)).toOpaque())
        if let element = AXElement.focused(inApp: pid) {
            focus(element)
            return
        }
        setCurrent(nil)
        PlatformLog.access.notice("no focused element at activation: \(app, privacy: .public)")
        let started = generation
        retries.start { [weak self, queue] in
            guard let observer = self else { return .moved }
            return await queue.run { observer.retry(generation: started, pid: pid) }
        }
    }

    private func retry(generation started: Int, pid: pid_t) -> FocusAttempt {
        guard started == generation, front?.pid == pid else { return .moved }
        guard let element = AXElement.focused(inApp: pid) else { return .missing }
        PlatformLog.access.notice("focused element appeared on a retry: \(self.front?.app ?? "unknown", privacy: .public)")
        focus(element)
        return .found
    }

    private func handle(_ notification: String, pid: pid_t) {
        guard front?.pid == pid else { return }
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            generation += 1
            retries.cancel()
            if let element = AXElement.focused(inApp: pid) { focus(element) } else { setCurrent(nil) }
        case kAXValueChangedNotification:
            if let current { emit(.edited(current.id)) }
        case kAXSelectedTextChangedNotification:
            if let current { emit(.caretMoved(current.id)) }
        default:
            break
        }
    }

    private func focus(_ element: AXElement) {
        guard let app = front?.app else { return setCurrent(nil) }
        let candidate = TextAccessRules.isFieldCandidate(role: element.role, subrole: element.subrole, appEnabled: isAppEnabled(app))
        let id = registry.focus(element, app: app, isCandidate: candidate, source: { RangeReader(element) })
        setCurrent(id.map { ($0, element) })
    }

    /// The same field focused again is no event: a focus event cancels the running checks.
    private func setCurrent(_ field: (id: FieldID, element: AXElement)?) {
        session?.watch(field?.element)
        let repeated = field != nil && current?.id == field?.id
        current = field
        if !repeated { emit(.focused(field?.id)) }
    }

    private func context(for pid: pid_t) -> ObserverContext {
        if let context = contexts[pid] { return context }
        let context = ObserverContext(observer: self, pid: pid)
        contexts[pid] = context
        return context
    }
}
