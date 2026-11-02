import AppKit
import ApplicationServices
import Foundation

private enum CPUStage {
    case starting
    case idle(CPUSample)
    case awaitingTyping
    case typing(CPUSample)
    case idleForced(CPUSample)
    case awaitingTypingForced
    case typingForced(CPUSample)
    case done
}

@MainActor
private final class FieldSession {
    let pid: pid_t
    let mode: AppAccessibilityMode
    var observation: FieldObservation
    var stage = CPUStage.starting
    var timer: Task<Void, Never>?
    var absorbFocusUntil: ContinuousClock.Instant?

    init(pid: pid_t, mode: AppAccessibilityMode, observation: FieldObservation) {
        self.pid = pid
        self.mode = mode
        self.observation = observation
    }
}

@MainActor
public final class Probe {
    private static let cpuWindow: Duration = .seconds(10)
    private static let evaluationDelay: Duration = .milliseconds(400)
    private static let focusSettle: Duration = .seconds(3)
    private static let excludedApps: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode",
        "com.apple.dt.Xcode", "dev.zed.Zed", "com.1password.1password", "com.bitwarden.desktop",
    ]

    private let queue = AXQueue()
    private let clock = ContinuousClock()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var running = false
    private var current: FieldSession?
    private var focusGeneration = 0
    private var lastKeystroke: ContinuousClock.Instant?
    private var observers: [pid_t: ProbeObserver] = [:]
    private var contexts: [pid_t: ProbeContext] = [:]
    private var enabledPIDs: Set<pid_t> = []
    private var evaluationTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    private var pendingRecheck = RecheckKind.scrolled
    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?

    public init() {}

    public func run(for duration: Duration) async {
        PlatformLog.probe.notice("probe starting")
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        PlatformLog.probe.notice("accessibility trusted at launch: \(trusted)")
        await ProbeModelRun.run()

        let giveUp = clock.now + duration
        while !AXIsProcessTrusted(), clock.now < giveUp {
            try? await clock.sleep(for: .seconds(1))
        }
        guard AXIsProcessTrusted() else {
            PlatformLog.probe.notice("accessibility never granted")
            return
        }
        start()
        try? await clock.sleep(for: duration)
        stop()
    }

    public func stop() {
        guard running else { return }
        running = false
        evaluationTask?.cancel()
        recheckTask?.cancel()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        if let current { finish(current) }
        current = nil
        let attached = Array(observers.values)
        observers = [:]
        Task { [queue] in
            await queue.run { attached.forEach { $0.detach() } }
        }
        PlatformLog.probe.notice("probe stopped")
    }

    func received(notification name: String, pid: pid_t) {
        guard running else { return }
        if let session = current, session.pid == pid {
            let recent = lastKeystroke.map { $0.duration(to: clock.now) <= FieldObservation.notificationWindow } ?? false
            session.observation.record(notification: name, afterKeystroke: recent)
        }
        switch name {
        case "AXFocusedUIElementChanged":
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { focusChanged(pid: pid) }
        case "AXValueChanged":
            scheduleEvaluation()
        case "AXWindowMoved":
            scheduleRecheck(.windowMoved)
        default:
            break
        }
    }

    private func start() {
        running = true
        monitors.append(contentsOf: [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let flags = event.modifierFlags
                let chord = flags.contains(.command) || flags.contains(.control)
                let undo = flags.contains(.command) && !flags.contains(.shift)
                    && event.charactersIgnoringModifiers?.lowercased() == "z"
                guard !chord || undo else { return }
                MainActor.assumeIsolated { self?.keystroke(isUndo: undo) }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRecheck(.scrolled) }
            },
        ].compactMap { $0 })
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.focusChanged(pid: pid) }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            focusChanged(pid: front)
        }
        PlatformLog.probe.notice("probe watching")
    }

    private func focusChanged(pid: pid_t) {
        guard running, pid != ownPID else { return }
        focusGeneration += 1
        let generation = focusGeneration
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        guard !Self.excludedApps.contains(bundleID) else {
            if let old = current { finish(old) }
            current = nil
            return
        }
        Task {
            let reading = await queue.run { FieldProbe.measure(pid: pid, formatting: nil) }
            guard generation == focusGeneration, running else { return }
            guard let reading else {
                if let old = current, old.pid != pid { finish(old); current = nil }
                return
            }
            if let session = current, session.pid == pid {
                if session.observation.identity == reading.identity { return }
                if let until = session.absorbFocusUntil, clock.now < until {
                    session.observation.absorb(reading)
                    return
                }
            }
            await begin(pid: pid, reading: reading)
        }
    }

    private func begin(pid: pid_t, reading: FieldReading) async {
        if let old = current { finish(old) }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        let session = FieldSession(
            pid: pid, mode: .forBundleID(bundleID),
            observation: FieldObservation(app: bundleID, reading: reading)
        )
        current = session
        if session.observation.line.isSecure { return }
        await retarget(pid: pid)
        guard session === current else { return }
        if enabledPIDs.contains(pid) {
            beginWindow(session) { .idleForced($0) }
        } else {
            beginWindow(session) { .idle($0) }
        }
    }

    private func finish(_ session: FieldSession) {
        session.timer?.cancel()
        let line = session.observation.finishedLine
        PlatformLog.probe.notice("\(line.render(), privacy: .public)")
        PlatformLog.probe.notice("frame readable: \(line.app, privacy: .public) \(line.role, privacy: .public) \(session.observation.hasFrame)")
    }

    private func retarget(pid: pid_t) async {
        let observer = observers[pid] ?? ProbeObserver(pid: pid)
        observers[pid] = observer
        let context = contexts[pid] ?? ProbeContext(probe: self, pid: pid)
        contexts[pid] = context
        let bits = Int(bitPattern: Unmanaged.passUnretained(context).toOpaque())
        await queue.run { observer.retarget(contextBits: bits) }
    }

    private func keystroke(isUndo: Bool) {
        lastKeystroke = clock.now
        guard let session = current, !session.observation.line.isSecure else { return }
        if isUndo { session.observation.recordUndo() }
        switch session.stage {
        case .idle, .awaitingTyping:
            beginWindow(session) { .typing($0) }
        case .idleForced, .awaitingTypingForced:
            beginWindow(session) { .typingForced($0) }
        default:
            break
        }
        scheduleEvaluation()
    }

    private func scheduleEvaluation() {
        evaluationTask?.cancel()
        guard let session = current, !session.observation.line.isSecure else { return }
        evaluationTask = Task {
            try? await clock.sleep(for: Self.evaluationDelay)
            guard !Task.isCancelled else { return }
            await evaluate(session)
        }
    }

    private func evaluate(_ session: FieldSession) async {
        guard session === current, !session.observation.line.isSecure else { return }
        let pid = session.pid
        let formatting = session.observation.formatting
        let reading = await queue.run { FieldProbe.measure(pid: pid, formatting: formatting) }
        guard session === current, let reading else { return }
        let shouldWrite = session.observation.shouldWrite(for: reading)
        session.observation.absorb(reading)
        guard shouldWrite else { return }

        let start = await queue.run { FieldProbe.write(pid: pid) }
        guard session === current, let start else { return }
        session.observation.recordWrite(start)
        await evaluate(session)
    }

    private func scheduleRecheck(_ kind: RecheckKind) {
        if kind == .windowMoved { pendingRecheck = .windowMoved }
        recheckTask?.cancel()
        guard let session = current, !session.observation.line.isSecure else { return }
        recheckTask = Task {
            try? await clock.sleep(for: Self.evaluationDelay)
            guard !Task.isCancelled else { return }
            await recheck(session)
        }
    }

    private func recheck(_ session: FieldSession) async {
        let kind = pendingRecheck
        pendingRecheck = .scrolled
        guard session === current, !session.observation.line.isSecure,
              let baseline = session.observation.baseline
        else { return }
        let pid = session.pid
        let result = await queue.run { FieldProbe.recheck(pid: pid, baseline: baseline, kind: kind) }
        guard session === current, case let .result(stable, updated) = result else { return }
        session.observation.recordBoundsCheck(stable: stable, baseline: updated)
    }

    private func beginWindow(_ session: FieldSession, _ stage: @escaping @Sendable (CPUSample) -> CPUStage) {
        session.timer?.cancel()
        session.stage = .starting
        let pid = session.pid
        session.timer = Task {
            let start = await queue.run { CPUSample.take(tree: pid) }
            guard !Task.isCancelled, session === current else { return }
            session.stage = stage(start)
            try? await clock.sleep(for: Self.cpuWindow)
            guard !Task.isCancelled, session === current else { return }
            await finishWindow(session)
        }
    }

    private func finishWindow(_ session: FieldSession) async {
        let pid = session.pid
        let end = await queue.run { CPUSample.take(tree: pid) }
        guard session === current else { return }
        switch session.stage {
        case let .idle(start):
            session.observation.line.cpuIdle = end.percent(since: start)
            session.stage = .awaitingTyping
        case let .typing(start):
            session.observation.line.cpuTyping = end.percent(since: start)
            guard session.mode != .native else {
                session.stage = .done
                return
            }
            await enableAccessibility(session)
            guard session === current else { return }
            beginWindow(session) { .idleForced($0) }
        case let .idleForced(start):
            session.observation.line.cpuIdleForced = end.percent(since: start)
            session.stage = .awaitingTypingForced
        case let .typingForced(start):
            session.observation.line.cpuTypingForced = end.percent(since: start)
            session.stage = .done
        default:
            break
        }
    }

    private func enableAccessibility(_ session: FieldSession) async {
        let pid = session.pid
        let mode = session.mode
        enabledPIDs.insert(pid)
        session.absorbFocusUntil = clock.now + Self.focusSettle
        await queue.run { mode.enable(on: AXElement.application(pid: pid).element) }
        await retarget(pid: pid)
    }
}
