#if DEBUG
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SkaldCore
import struct SkaldCore.TextRange

/// The focused field of an app, found as the app finds it, with the one-unit range at its caret.
private struct ScrollTarget: Sendable {
    let bundleID: String
    let reader: any FieldReader
    let range: TextRange
    let frame: CGRect?

    /// Called on `AXQueue` only.
    static func resolve(pid: pid_t, bundleID: String, enabling mode: AppAccessibilityMode?) -> ScrollTarget? {
        mode?.enable(on: AXElement.application(pid: pid).element)
        guard let focused = AXElement.focused(inApp: pid), let field = EditableResolver.field(for: focused),
              TextAccessRules.isFieldCandidate(role: field.role, subrole: field.subrole, appEnabled: true),
              let reader = FieldSource.reader(for: field), let selection = reader.selection(), let length = reader.length(),
              let range = TextAccessRules.boundsProbeRange(selection: selection, totalLength: length)
        else { return nil }
        return ScrollTarget(bundleID: bundleID, reader: reader, range: range, frame: field.frame.flatMap { AXElement.usable($0) })
    }

    /// Called on `AXQueue` only.
    func bounds() -> CGRect? {
        if case let .found(rect) = reader.boundsRead(for: range) { rect } else { nil }
    }
}

/// Measures how long an app's Accessibility bounds lag behind a scroll, for the apps' ceilings the overlay waits
/// for. It logs and writes app identifiers, scroll kinds and milliseconds, never text.
@MainActor
public final class ScrollLagProbe {
    private static let quitAfter: Duration = .seconds(10 * 60)
    private static let sampleInterval: Duration = .milliseconds(10)
    private static let idleRequired: Double = 8
    private static let anyInput = CGEventType(rawValue: UInt32.max)!

    private let queue = AXQueue()
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var running = false
    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?
    private var enabledPIDs: Set<pid_t> = []
    private var target: ScrollTarget?
    private var targetGeneration = 0
    private var trace: ScrollLagTrace?
    private var lastScrollAt: Duration = .zero
    private var gesture: Task<Void, Never>?
    private var ignoredScrolls = 0
    private var results: [String: [ScrollKind: [Duration?]]] = [:]
    private var savedPointer: CGPoint?

    public init() {}

    public static func outputURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: SkaldCore.bundleID, directoryHint: .isDirectory)
            .appending(path: "probe", directoryHint: .isDirectory)
            .appending(path: "scroll-lag.json", directoryHint: .notDirectory)
    }

    /// Watches every scroll for 10 minutes, or with `drive` posts its own until every kind has been driven.
    public func run(drive: Bool) async {
        PlatformLog.probe.notice("scroll probe starting, drive \(drive)")
        guard AXIsProcessTrusted() else {
            PlatformLog.probe.notice("scroll probe: accessibility not granted")
            return
        }
        start()
        await refreshTarget()
        if drive {
            await self.drive()
        } else {
            try? await clock.sleep(for: Self.quitAfter)
        }
        stop()
    }

    public func stop() {
        guard running else { return }
        running = false
        gesture?.cancel()
        gesture = nil
        trace = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        if let savedPointer { CGWarpMouseCursorPosition(savedPointer) }
        savedPointer = nil
        write()
        PlatformLog.probe.notice("scroll probe stopped, \(self.ignoredScrolls) scroll events came with no field to read")
    }

    // MARK: Watching

    private func start() {
        running = true
        monitors.append(contentsOf: [
            NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let kind = Self.kind(of: event)
                MainActor.assumeIsolated { self?.scrolled(kind) }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWhenIdle() }
            },
        ].compactMap { $0 })
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWhenIdle() }
        }
    }

    private nonisolated static func kind(of event: NSEvent) -> ScrollKind {
        if event.momentumPhase != [] { return .momentum }
        return event.hasPreciseScrollingDeltas ? .trackpad : .wheel
    }

    private func elapsed() -> Duration {
        origin.duration(to: clock.now)
    }

    private func refreshWhenIdle() {
        guard running, trace == nil else { return }
        Task { await refreshTarget() }
    }

    /// The frontmost app other than Skald, as the app finds its focused field. A newer refresh wins.
    private func refreshTarget() async {
        targetGeneration += 1
        let generation = targetGeneration
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else {
            target = nil
            return
        }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? "unknown"
        guard !Settings.defaultOffApps.contains(bundleID) else {
            target = nil
            return
        }
        let mode = AppAccessibilityMode.forBundleID(bundleID)
        let enabling: AppAccessibilityMode? = mode != .native && enabledPIDs.insert(pid).inserted ? mode : nil
        let resolved = await queue.run { ScrollTarget.resolve(pid: pid, bundleID: bundleID, enabling: enabling) }
        guard generation == targetGeneration else { return }
        target = resolved
    }

    // MARK: Gestures

    private func scrolled(_ kind: ScrollKind) {
        guard running else { return }
        let now = elapsed()
        lastScrollAt = now
        if trace != nil {
            trace?.scrolled(kind, at: now)
            return
        }
        guard let target else {
            ignoredScrolls += 1
            return
        }
        var started = ScrollLagTrace()
        started.scrolled(kind, at: now)
        trace = started
        gesture = Task { await follow(target) }
    }

    /// Samples every 10 ms until the trace settles or gives up, then once more at the final check.
    private func follow(_ target: ScrollTarget) async {
        while running, !Task.isCancelled, let current = trace {
            let now = elapsed()
            if current.isSettled(at: now) {
                guard now - lastScrollAt >= ScrollLagTrace.finalCheck else {
                    try? await clock.sleep(for: Self.sampleInterval)
                    continue
                }
                let final = await queue.run { target.bounds() }
                trace?.checkedFinally(final)
                break
            }
            let bounds = await queue.run { target.bounds() }
            trace?.sampled(bounds, at: elapsed())
            if trace?.gaveUp(at: elapsed()) == true { break }
            try? await clock.sleep(for: Self.sampleInterval)
        }
        guard running, !Task.isCancelled, let finished = trace else { return }
        record(finished, for: target.bundleID)
        trace = nil
        gesture = nil
        await refreshTarget()
    }

    private func record(_ finished: ScrollLagTrace, for bundleID: String) {
        guard let kind = finished.kind, let lag = finished.lag else {
            PlatformLog.probe.notice("scroll lag: \(bundleID, privacy: .public): no bounds")
            return
        }
        let settled: Duration? = finished.isUnsettled ? nil : lag
        results[bundleID, default: [:]][kind, default: []].append(settled)
        let text = settled.map { "\(Int(($0 / .milliseconds(1)).rounded())) ms" } ?? "unsettled"
        PlatformLog.probe.notice("scroll lag: \(bundleID, privacy: .public) \(kind.rawValue, privacy: .public): \(text, privacy: .public)")
    }

    private func write() {
        let url = Self.outputURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ScrollLagSummary.json(byApp: results).write(to: url, options: .atomic)
            PlatformLog.probe.notice("scroll lag written for \(self.results.count) apps")
        } catch {
            PlatformLog.probe.notice("scroll lag: write failed")
        }
        for (bundleID, byKind) in results.sorted(by: { $0.key < $1.key }) {
            let ceiling = ScrollLagSummary.ceiling(byKind: byKind).map { "\(Int(($0 / .milliseconds(1)).rounded())) ms" } ?? "none"
            PlatformLog.probe.notice("scroll lag ceiling: \(bundleID, privacy: .public): \(ceiling, privacy: .public)")
        }
    }

    // MARK: Driving

    /// Twenty gestures per kind, alternating down and up, each started only after the Mac has had no hardware
    /// input for 8 s. The events come from a private event source, so they are not hardware input.
    private func drive() async {
        guard let frame = target?.frame else {
            PlatformLog.probe.notice("scroll probe: no focused field with a frame to drive")
            return
        }
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        await waitForQuiet()
        guard running else { return }
        savedPointer = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(centre)
        try? await clock.sleep(for: .milliseconds(200))
        click(at: centre, source: source)
        try? await clock.sleep(for: .milliseconds(500))
        await refreshTarget()

        for kind in ScrollKind.allCases {
            for number in 0..<ScrollLagSummary.gestures {
                await waitForQuiet()
                guard running else { return }
                await post(kind, down: number.isMultiple(of: 2), at: centre, source: source)
                await finishedGesture()
            }
        }
    }

    private func waitForQuiet() async {
        while running, CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInput) < Self.idleRequired {
            try? await clock.sleep(for: .milliseconds(500))
        }
    }

    /// The gesture the posted events started, when the monitor saw them, through its final check.
    private func finishedGesture() async {
        let deadline = clock.now + .seconds(1)
        while running, gesture == nil, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(20))
        }
        if gesture == nil { PlatformLog.probe.notice("scroll probe: a posted gesture raised no scroll event") }
        while running, gesture != nil {
            try? await clock.sleep(for: .milliseconds(50))
        }
    }

    private func click(at point: CGPoint, source: CGEventSource) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    private func post(_ kind: ScrollKind, down: Bool, at point: CGPoint, source: CGEventSource) async {
        let sign: Int32 = down ? -1 : 1
        func send(_ units: CGScrollEventUnit, _ delta: Int32, scroll: Int64 = 0, momentum: Int64 = 0) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: source, units: units, wheelCount: 1, wheel1: delta * sign, wheel2: 0, wheel3: 0
            ) else { return }
            event.location = point
            if units == .pixel {
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            }
            event.post(tap: .cghidEventTap)
        }
        // Scroll phases: began 1, changed 2, ended 4. Momentum phases: begin 1, continue 2, end 3.
        func trackpad() async {
            for index in 0..<8 {
                send(.pixel, 5, scroll: index == 0 ? 1 : index == 7 ? 4 : 2)
                try? await clock.sleep(for: .milliseconds(16))
            }
        }
        switch kind {
        case .wheel:
            for _ in 0..<3 {
                send(.line, 1)
                try? await clock.sleep(for: .milliseconds(20))
            }
        case .trackpad:
            await trackpad()
        case .momentum:
            await trackpad()
            let deltas: [Int32] = [5, 4, 4, 3, 3, 2, 2, 1, 1, 1]
            for (index, delta) in deltas.enumerated() {
                send(.pixel, delta, momentum: index == 0 ? 1 : index == deltas.count - 1 ? 3 : 2)
                try? await clock.sleep(for: .milliseconds(16))
            }
        }
    }
}
#endif
