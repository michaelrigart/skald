import ApplicationServices
import Foundation
import SkaldCore
import struct SkaldCore.TextRange

/// Text access on macOS 27 through Accessibility: fields read through character ranges, written through
/// Accessibility where finding 7 measured that as clean. Every Accessibility call runs on `AXQueue`.
public final class SystemTextAccess: TextAccess {
    public let events: AsyncStream<FieldEvent>

    private let queue = AXQueue()
    private let isAppEnabled: @Sendable (String) -> Bool
    private let observer: FieldObserver
    private let waits: FocusWaits

    public init(isAppEnabled: @escaping @Sendable (String) -> Bool, clock: any Clock<Duration>) {
        let (events, continuation) = AsyncStream.makeStream(of: FieldEvent.self)
        let waits = FocusWaits(clock: clock)
        self.events = events
        self.isAppEnabled = isAppEnabled
        self.waits = waits
        observer = FieldObserver(queue: queue, clock: clock, isAppEnabled: isAppEnabled) { event in
            continuation.yield(event)
            if case .focused(let field?) = event { waits.focused(field) }
        }
        observer.start()
    }

    public func snapshot(of field: FieldID) async -> FieldSnapshot? {
        guard isAppEnabled(field.app) else { return nil }
        return await queue.run { [observer] in
            observer.entry(field).flatMap { TextAccessRules.snapshot(of: field, reader: $0.source) }
        }
    }

    public func capabilities(for app: String) async -> AccessCapabilities {
        guard isAppEnabled(app) else { return [] }
        let access = CapabilityTable.access(for: app)
        guard !access.probed.isEmpty else { return access.capabilities }
        let measured = await queue.run { [observer] () -> AccessCapabilities in
            guard let entry = observer.newest(app: app) else { return [] }
            var found: AccessCapabilities = []
            if access.probed.contains(.fieldFrame), entry.element.frame.flatMap({ AXElement.usable($0) }) != nil {
                found.insert(.fieldFrame)
            }
            let reader = entry.source
            if access.probed.contains(.rangeBounds), let total = reader.length(), let selection = reader.selection(),
               let probe = TextAccessRules.boundsProbeRange(selection: selection, totalLength: total), reader.bounds(for: probe) != nil {
                found.insert(.rangeBounds)
            }
            return found
        }
        return CapabilityTable.capabilities(access, measured: measured)
    }

    public func capture(of field: FieldID) async -> SelectionCapture? {
        guard isAppEnabled(field.app) else { return nil }
        return await queue.run { [observer] in
            observer.entry(field).flatMap { TextAccessRules.capture(of: field, reader: $0.source) }
        }
    }

    public func replace(_ range: TextRange, expected: ExpectedText, with text: String, in field: FieldID) async -> ReplaceOutcome {
        guard isAppEnabled(field.app) else { return .unsupported }
        let access = CapabilityTable.access(for: field.app)
        let step = await queue.run { [observer] () -> ReplaceRun in
            guard let entry = observer.entry(field) else { return .done(.refusedOtherField) }
            let decision = TextAccessRules.replaceStep(
                range, expected: expected, isFocusedField: observer.isFocused(entry),
                currentText: { entry.source.string(for: expected.range) }, access: access
            )
            switch decision {
            case .refuse(let outcome):
                return .done(outcome)
            case .write(.accessibility):
                return .done(AccessibilityWrite.perform(
                    range, with: text, expected: expected, reader: entry.source,
                    setSelectedText: { entry.element.setSelectedText($0) == .success },
                    isFocused: { observer.isFocused(entry) }
                ))
            case .write(.paste):
                return .paste
            }
        }
        let outcome: ReplaceOutcome
        switch step {
        case .done(let done): outcome = done
        case .paste: outcome = await pasteWrite(range, expected: expected, with: text, in: field)
        }
        PlatformLog.access.notice("replace: \(field.app, privacy: .public): \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// Screen bounds of a character range, top-left origin, for the underlines.
    public func bounds(_ r: TextRange, in field: FieldID) async -> CGRect? {
        await queue.run { [observer] in observer.entry(field)?.source.bounds(for: r) }
    }

    /// The field's frame on screen, top-left origin, for the badge.
    public func frame(of field: FieldID) async -> CGRect? {
        await queue.run { [observer] in observer.entry(field)?.element.frame.flatMap { AXElement.usable($0) } }
    }

    /// True once `field` is the focused element of the focused app again, false after `timeout`.
    public func waitForFocus(on field: FieldID, timeout: Duration) async -> Bool {
        await waits.wait(for: field, timeout: timeout) { [queue, observer] in
            await queue.run { observer.entry(field).map { observer.isFocused($0) } ?? false }
        }
    }

    /// Task 19's paste writer; until then a paste app's Accept offers Copy.
    private func pasteWrite(_ range: TextRange, expected: ExpectedText, with text: String, in field: FieldID) async -> ReplaceOutcome {
        .unsupported
    }
}

private enum ReplaceRun: Sendable {
    case done(ReplaceOutcome)
    case paste
}

/// Select the range, set the selected text, read back the paragraph, then apply the caret rule.
enum AccessibilityWrite {
    static func perform(
        _ range: TextRange, with text: String, expected: ExpectedText, reader: some FieldReader,
        setSelectedText: (String) -> Bool, isFocused: () -> Bool
    ) -> ReplaceOutcome {
        let user = reader.selection()
        func finish(_ end: WriteEnd, left: TextRange?) {
            guard let user,
                  let target = TextAccessRules.caretTarget(user: user, replaced: range, replacementLength: text.utf16.count, end: end)
            else { return }
            let current = reader.selection()
            guard TextAccessRules.restoresCaret(stillFocused: isFocused(), current: current, left: left), current != target else { return }
            _ = reader.select(target)
        }

        guard reader.select(range), reader.selection() == range else {
            finish(.abortedAfterSelecting, left: reader.selection())
            return .failed
        }
        guard setSelectedText(text) else {
            finish(.abortedAfterSelecting, left: reader.selection())
            return .failed
        }
        let left = reader.selection()
        let revised = TextAccessRules.applying(text, at: range, to: expected)
        guard reader.string(for: revised.range) == revised.text else {
            finish(.abortedAfterSelecting, left: left)
            return .failed
        }
        finish(.confirmed, left: left)
        return .replaced
    }
}

/// Callers waiting for a field to be focused again, answered by the observer's focus events or a timeout.
final class FocusWaits: @unchecked Sendable { // reason: waiters are only touched under the lock
    private struct Waiter {
        let field: FieldID
        var continuation: CheckedContinuation<Bool, Never>?
        var result: Bool?
    }

    private let sleep: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var waiters: [UUID: Waiter] = [:]

    init<C: Clock<Duration>>(clock: C) {
        sleep = { try await clock.sleep(for: $0) }
    }

    func wait(for field: FieldID, timeout: Duration, isFocusedNow: @Sendable () async -> Bool) async -> Bool {
        let id = UUID()
        lock.withLock { waiters[id] = Waiter(field: field) }
        if await isFocusedNow() { resolve(id, true) }
        let timer = Task { [sleep] in
            try? await sleep(timeout)
            self.resolve(id, false)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let ready = lock.withLock { () -> Bool? in
                    guard let result = waiters[id]?.result else {
                        waiters[id]?.continuation = continuation
                        return nil
                    }
                    waiters[id] = nil
                    return result
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            resolve(id, false)
        }
    }

    func focused(_ field: FieldID) {
        let ids = lock.withLock { waiters.filter { $0.value.field == field }.map(\.key) }
        ids.forEach { resolve($0, true) }
    }

    /// The first answer wins; a waiter not yet suspended keeps it until it asks.
    private func resolve(_ id: UUID, _ value: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard var waiter = waiters[id], waiter.result == nil else { return nil }
            guard let continuation = waiter.continuation else {
                waiter.result = value
                waiters[id] = waiter
                return nil
            }
            waiters[id] = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }
}
