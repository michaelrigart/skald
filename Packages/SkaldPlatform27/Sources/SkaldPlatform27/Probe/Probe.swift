import AppKit
import ApplicationServices
import Foundation
import SkaldCore

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

private enum WindowPhase: Sendable {
    case idle, typing, idleForced, typingForced

    var typed: WindowPhase {
        switch self {
        case .idle: .typing
        case .idleForced: .typingForced
        default: self
        }
    }

    func stage(_ start: CPUSample) -> CPUStage {
        switch self {
        case .idle: .idle(start)
        case .typing: .typing(start)
        case .idleForced: .idleForced(start)
        case .typingForced: .typingForced(start)
        }
    }
}

@MainActor
private final class FieldSession {
    let pid: pid_t
    let mode: AppAccessibilityMode
    var observation: FieldObservation
    var stage = CPUStage.starting
    var timer: Task<Void, Never>?
    var typedWhileStarting = false
    var undoPending = false
    var loggedMarkerPosition = false
    var loggedCaret = false
    var loggedKind = false
    var markerRetries = 0
    var retryGaveUp = false
    var retryTask: Task<Void, Never>?
    var loggedSources = false
    var loggedQuietWait = false
    var lastValueChange: ContinuousClock.Instant?
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
    private static let grantWait: Duration = .seconds(5 * 60)
    private static let writeSettle: Duration = .milliseconds(500)
    private static let latePasteWait: Duration = .seconds(1)
    private static let undoMeasurementDelay: Duration = .milliseconds(250)

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
    private var diagnosedPIDs: Set<pid_t> = []
    private var diagnosingPIDs: Set<pid_t> = []
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

        let giveUp = clock.now + Self.grantWait
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
        let ownSession = current.flatMap { $0.pid == pid ? $0 : nil }
        if let session = ownSession {
            let recent = lastKeystroke.map { $0.duration(to: clock.now) <= FieldObservation.notificationWindow } ?? false
            session.observation.record(notification: name, afterKeystroke: recent)
            if name == "AXValueChanged" { session.lastValueChange = clock.now }
        }
        switch name {
        case "AXFocusedUIElementChanged":
            FocusedSearchCache.shared.clear(pid: pid)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { focusChanged(pid: pid) }
        case "AXValueChanged" where ownSession != nil:
            scheduleEvaluation()
        case "AXWindowMoved" where ownSession != nil:
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
        FocusedSearchCache.shared.clear(pid: pid)
        focusGeneration += 1
        let generation = focusGeneration
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        guard !Settings.defaultOffApps.contains(bundleID) else {
            if let old = current { finish(old) }
            current = nil
            return
        }
        Task {
            var reading = await queue.run { FieldProbe.measure(pid: pid, formatting: nil) }
            guard generation == focusGeneration, running else { return }
            let mode = AppAccessibilityMode.forBundleID(bundleID)
            if reading == nil, mode != .native, !enabledPIDs.contains(pid) {
                PlatformLog.probe.notice("no focused element: \(bundleID, privacy: .public)")
                enabledPIDs.insert(pid)
                await enable(mode, pid: pid, app: bundleID)
                if let session = current, session.pid == pid { moveToForced(session) }
                await retarget(pid: pid)
                reading = await queue.run { FieldProbe.measure(pid: pid, formatting: nil) }
                guard generation == focusGeneration, running else { return }
            }
            if reading == nil, mode != .native, !diagnosedPIDs.contains(pid), diagnosingPIDs.insert(pid).inserted {
                Task { await diagnoseMissingFocus(pid: pid, generation: generation, app: bundleID) }
            }
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
        beginWindow(session, enabledPIDs.contains(pid) ? .idleForced : .idle)
    }

    private func finish(_ session: FieldSession) {
        session.timer?.cancel()
        WebAreaLog.shared.endSession(pid: session.pid)
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
        session.markerRetries = 0
        session.retryGaveUp = false
        session.retryTask?.cancel()
        if isUndo {
            session.observation.recordUndo()
            session.undoPending = true
            if session.observation.hasWrite { measureAfterUndo(session, press: session.observation.undoPresses) }
        } else {
            session.observation.recordTyping()
        }
        switch session.stage {
        case .starting:
            session.typedWhileStarting = true
        case .idle, .awaitingTyping:
            beginWindow(session, .typing)
        case .idleForced, .awaitingTypingForced:
            beginWindow(session, .typingForced)
        default:
            break
        }
        scheduleEvaluation()
    }

    private static func describeKind(_ reading: FieldReading) -> String {
        guard reading.kind == .textMarkers else { return reading.kind.rawValue }
        let caret = reading.selection.map { String($0.location) } ?? "none"
        let length = reading.value.map { String(($0 as NSString).length) } ?? "none"
        return "\(reading.kind.rawValue), caret offset \(caret), text length \(length)"
    }

    /// One measurement per ⌘Z, not cancelled by later keystrokes, so each press is judged on its own state.
    private func measureAfterUndo(_ session: FieldSession, press: Int) {
        Task {
            try? await clock.sleep(for: Self.undoMeasurementDelay)
            guard session === current else { return }
            let pid = session.pid
            let formatting = session.observation.formatting
            let forced = session.observation.writeKind
            let reading = await queue.run { FieldProbe.measure(pid: pid, formatting: formatting, forcing: forced) }
            guard session === current, let reading else { return }
            session.observation.absorb(reading)
            let check = reading.value.flatMap { session.observation.writeCheck($0) } ?? "value unreadable"
            PlatformLog.probe.notice("after undo \(press): \(session.observation.line.app, privacy: .public): \(check, privacy: .public)")
        }
    }

    /// Not tied to the evaluation task, so measurements and notifications do not cancel it; a keystroke does.
    private func scheduleMarkerRetry(_ session: FieldSession) {
        session.retryTask?.cancel()
        session.retryTask = Task {
            try? await clock.sleep(for: MarkerRetry.interval)
            guard !Task.isCancelled, session === current else { return }
            await evaluate(session)
        }
    }

    private func scheduleEvaluation(after delay: Duration = Probe.evaluationDelay) {
        evaluationTask?.cancel()
        guard let session = current, !session.observation.line.isSecure else { return }
        evaluationTask = Task {
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await evaluate(session)
        }
    }

    private func evaluate(_ session: FieldSession) async {
        guard session === current, !session.observation.line.isSecure else { return }
        let pid = session.pid
        let formatting = session.observation.formatting
        let forced = session.observation.writeKind
        let reading = await queue.run { FieldProbe.measure(pid: pid, formatting: formatting, forcing: forced) }
        guard session === current, let reading else { return }
        let app = session.observation.line.app
        if !session.loggedKind {
            session.loggedKind = true
            PlatformLog.probe.notice("field kind: \(app, privacy: .public): \(Self.describeKind(reading), privacy: .public)")
            if reading.kind == .textMarkers {
                let ancestor = await queue.run { FieldProbe.editableAncestorDiagnosis(pid: pid) }
                PlatformLog.probe.notice("marker field editable ancestor: \(app, privacy: .public): \(ancestor, privacy: .public)")
            }
        }
        let shouldWrite = session.observation.shouldWrite(for: reading)
        if !shouldWrite, !session.loggedMarkerPosition, session.observation.awaitingWrite,
           let tail = reading.value.flatMap({ ProbeMarker.tailSummary(of: $0) })
        {
            session.loggedMarkerPosition = true
            PlatformLog.probe.notice("marker not at the end: \(app, privacy: .public): \(tail, privacy: .public)")
        }
        if !shouldWrite, !session.loggedCaret, session.observation.awaitingWrite, let value = reading.value,
           let caret = ProbeMarker.caretSummary(of: value, caret: reading.selection, characterCount: reading.characterCount)
        {
            session.loggedCaret = true
            PlatformLog.probe.notice("marker not accepted: \(app, privacy: .public): \(caret, privacy: .public)")
        }
        if !session.loggedSources, session.observation.awaitingWrite, reading.sources.contains(where: \.containsMarker) {
            session.loggedSources = true
            PlatformLog.probe.notice("marker sources: \(app, privacy: .public): \(reading.sources.map(\.description).joined(separator: "; "), privacy: .public)")
        }
        session.observation.absorb(reading)
        if session.undoPending, let value = reading.value, let check = session.observation.writeCheck(value) {
            session.undoPending = false
            PlatformLog.probe.notice("after undo: \(app, privacy: .public): \(check, privacy: .public)")
        }
        switch MarkerRetry.step(
            attempts: session.markerRetries, containsMarker: session.observation.awaitingWrite && reading.containsMarker, placed: shouldWrite
        ) {
        case let .retry(attempt):
            session.markerRetries = attempt
            scheduleMarkerRetry(session)
        case let .placed(attempts):
            session.markerRetries = 0
            PlatformLog.probe.notice("marker placed after \(attempts) retries: \(app, privacy: .public)")
        case let .gaveUp(attempts):
            if !session.retryGaveUp {
                session.retryGaveUp = true
                PlatformLog.probe.notice("marker not placed after \(attempts) retries: \(app, privacy: .public)")
            }
        case .idle:
            break
        }
        guard shouldWrite else { return }

        let method: WriteMethod = reading.kind == .textMarkers ? .paste : WriteMethod(for: session.mode)
        if method == .paste,
           let wait = QuietPeriod.remaining(now: clock.now, lastKeystroke: lastKeystroke, lastValueChange: session.lastValueChange)
        {
            if !session.loggedQuietWait {
                session.loggedQuietWait = true
                PlatformLog.probe.notice("paste waits for a quiet period: \(app, privacy: .public): \(Int(wait / .milliseconds(1))) ms to go")
            }
            scheduleEvaluation(after: wait)
            return
        }
        session.observation.beginWrite()
        let attempt: WriteAttempt?
        switch method {
        case .ax: attempt = await queue.run { FieldProbe.write(pid: pid) }
        case .paste: attempt = await pasteWrite(session)
        }
        session.observation.endWrite()
        guard session === current else { return }
        guard let attempt else {
            PlatformLog.probe.notice("write skipped: \(app, privacy: .public): the marker was gone when the write started")
            return
        }
        switch attempt {
        case let .started(start):
            session.observation.recordWrite(start)
            await evaluate(session)
            guard session === current, !session.observation.line.canWrite else { return }
            let settleStart = clock.now
            try? await clock.sleep(for: Self.writeSettle)
            let settled = Int(settleStart.duration(to: clock.now) / .milliseconds(1))
            guard session === current else { return }
            let laterFormatting = session.observation.formatting
            let forced = session.observation.writeKind
            let later = await queue.run { FieldProbe.measure(pid: pid, formatting: laterFormatting, forcing: forced) }
            guard session === current, let later else { return }
            session.observation.absorb(later)
            let check = later.value.flatMap { session.observation.writeCheck($0) } ?? "value unreadable"
            PlatformLog.probe.notice("after write (\(settled) ms): \(app, privacy: .public): matched \(session.observation.line.canWrite): \(check, privacy: .public)")
        case let .aborted(reason):
            session.observation.recordWriteAborted()
            PlatformLog.probe.notice("write aborted: \(session.observation.line.app, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// Pasteboard work stays on the main actor; the AX queue only selects, re-checks and posts.
    private func pasteWrite(_ session: FieldSession) async -> WriteAttempt? {
        let pid = session.pid
        let swap = PasteboardSwap()
        guard swap.canRestoreFaithfully else {
            return .aborted(reason: "paste skipped: clipboard holds concealed or promised content")
        }
        let preparation = await queue.run { FieldProbe.prepare(pid: pid, method: .paste) }
        let prepared: PreparedWrite
        switch preparation {
        case nil: return nil
        case let .aborted(reason): return .aborted(reason: reason)
        case let .ready(found): prepared = found
        }
        guard session === current else {
            _ = await queue.run { FieldProbe.cancel(prepared) }
            return nil
        }
        let staging = swap.stage(ProbeMarker.replacement)
        if let refusal = staging.refusal {
            let selection = await queue.run { FieldProbe.cancel(prepared) }
            return .aborted(reason: "\(refusal); \(selection)")
        }
        let attempt = await queue.run { FieldProbe.writeByPaste(prepared, pid: pid) }
        let restoration = swap.restore()
        switch attempt {
        case let .aborted(reason):
            return .aborted(reason: "\(reason); \(PasteWrite.describe(restoration))")
        case let .sent(start, outcome):
            PlatformLog.probe.notice("write sent (paste): pid \(pid): selection on the marker after \(outcome.selectionWaitedMs) ms, \(PasteWrite.describe(outcome), privacy: .public), \(PasteWrite.describe(restoration), privacy: .public)")
            watchForLatePaste(prepared.field, kind: prepared.kind, seen: outcome.finalValue, app: session.observation.line.app)
            return .started(start)
        }
    }

    /// A slow app may apply the paste after the restore: look again once, a second later, in lengths only.
    private func watchForLatePaste(_ field: AXElement, kind: FieldKind, seen: String?, app: String) {
        Task {
            try? await clock.sleep(for: Self.latePasteWait)
            let later = await queue.run { FieldProbe.text(of: field, kind: kind) }
            guard later != seen else { return }
            let before = seen.map { String(($0 as NSString).length) } ?? "unreadable"
            let after = later.map { String(($0 as NSString).length) } ?? "unreadable"
            PlatformLog.probe.notice("value changed after the restore: \(app, privacy: .public): \(before, privacy: .public) units before, \(after, privacy: .public) after")
        }
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
        session.observation.recordBoundsCheck(kind, stable: stable, baseline: updated)
    }

    private func beginWindow(_ session: FieldSession, _ phase: WindowPhase) {
        session.timer?.cancel()
        session.stage = .starting
        let pid = session.pid
        session.timer = Task {
            let start = await queue.run { CPUSample.take(tree: pid) }
            guard !Task.isCancelled, session === current else { return }
            session.stage = (session.typedWhileStarting ? phase.typed : phase).stage(start)
            session.typedWhileStarting = false
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
            beginWindow(session, .idleForced)
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

    private func moveToForced(_ session: FieldSession) {
        switch session.stage {
        case .starting, .idle:
            beginWindow(session, .idleForced)
        case .typing:
            beginWindow(session, .typingForced)
        case .awaitingTyping:
            session.timer?.cancel()
            session.stage = .awaitingTypingForced
        default:
            break
        }
    }

    private func enableAccessibility(_ session: FieldSession) async {
        let pid = session.pid
        let mode = session.mode
        enabledPIDs.insert(pid)
        session.absorbFocusUntil = clock.now + Self.focusSettle
        await enable(mode, pid: pid, app: session.observation.line.app)
        await retarget(pid: pid)
    }

    private func enable(_ mode: AppAccessibilityMode, pid: pid_t, app: String) async {
        let results = await queue.run { mode.enable(on: AXElement.application(pid: pid).element) }
        PlatformLog.probe.notice("accessibility enabled: \(app, privacy: .public): \(results.map(\.summary).joined(separator: ", "), privacy: .public)")
    }

    /// The probe may sleep: look at the focus query right after enabling, then again after 1 s and 3 s.
    private func diagnoseMissingFocus(pid: pid_t, generation: Int, app: String) async {
        defer { diagnosingPIDs.remove(pid) }
        var waited = 0
        for target in [0, 1000, 3000] {
            if target > waited {
                try? await clock.sleep(for: .milliseconds(target - waited))
                waited = target
            }
            guard running, generation == focusGeneration else { return }
            let diagnosis = await queue.run { FocusDiagnosis.take(pid: pid) }
            guard running, generation == focusGeneration else { return }
            PlatformLog.probe.notice("focus retry: \(app, privacy: .public): \(diagnosis.summary(afterMs: target), privacy: .public)")
        }
        diagnosedPIDs.insert(pid)
    }
}
