import ApplicationServices
import Foundation
import SkaldCore
import struct SkaldCore.TextRange

/// Why the focused field may have moved on screen.
public enum GeometryChange: Sendable, Equatable {
    case window, caret
}

/// Text access on macOS 27 through Accessibility: fields read through character ranges or text markers, written
/// through Accessibility or by paste where finding 7 measured that as clean. Every Accessibility call runs on
/// `AXQueue`; pasteboard work runs on the main actor.
public final class SystemTextAccess: TextAccess {
    public let events: AsyncStream<FieldEvent>
    /// The focused field may have moved on screen: one of its app's windows moved or changed size, or the
    /// caret moved, which can scroll the field.
    public let geometryChanges: AsyncStream<GeometryChange>

    private let queue = AXQueue()
    private let isAppEnabled: @Sendable (String) -> Bool
    private let observer: FieldObserver
    private let waits: FocusWaits
    private let writer: PasteWriter

    public init(isAppEnabled: @escaping @Sendable (String) -> Bool, clock: any Clock<Duration>) {
        let (events, continuation) = AsyncStream.makeStream(of: FieldEvent.self)
        let (geometryChanges, geometry) = AsyncStream.makeStream(of: GeometryChange.self)
        let waits = FocusWaits(clock: clock)
        let changes = ValueChanges()
        let writer = PasteWriter(clock: PasteClock(clock), changes: changes)
        self.events = events
        self.geometryChanges = geometryChanges
        self.isAppEnabled = isAppEnabled
        self.waits = waits
        self.writer = writer
        observer = FieldObserver(queue: queue, clock: clock, isAppEnabled: isAppEnabled, moved: { geometry.yield(.window) }) { event in
            continuation.yield(event)
            if let change = TextAccessRules.geometryChange(for: event) { geometry.yield(change) }
            switch event {
            case .focused(let field?):
                waits.focused(field)
                Task { @MainActor in await writer.fieldChanged(field) }
            case .edited(let field):
                changes.changed(field)
                Task { @MainActor in await writer.fieldChanged(field) }
            case .focused(nil), .caretMoved:
                break
            }
        }
        observer.start()
    }

    /// Accessibility was granted after launch: observe the frontmost app now, not at its next activation.
    public func observeFrontmostApp() {
        observer.reactivate()
    }

    /// The app switches changed: a frontmost app turned off ends its field at once (`focused(nil)`), and one
    /// turned on is observed without waiting for its next activation.
    public func appSwitchesChanged() {
        observer.switchesChanged()
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

    /// The field focused right now in an app Skald is on in, or nil; the panel captures it.
    public func focusedField() async -> FieldID? {
        await queue.run { [observer] in observer.focusedField() }
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
                read: { entry.source.string(for: $0) }, length: { entry.source.length() }, access: access
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

    /// Screen bounds of each range in one `AXQueue` job, nil where there are none; after the app first fails to
    /// answer in time, the rest are nil without being asked for.
    public func bounds(_ ranges: [TextRange], in field: FieldID) async -> [CGRect?] {
        await queue.run { [observer] in
            guard let reader = observer.entry(field)?.source else { return ranges.map { _ in nil } }
            return TextAccessRules.bounds(of: ranges) { reader.boundsRead(for: $0) }
        }
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

    private func pasteWrite(_ range: TextRange, expected: ExpectedText, with text: String, in field: FieldID) async -> ReplaceOutcome {
        let target = AXPasteTarget(queue: queue, observer: observer, field: field, range: range, original: expected, replacement: text)
        return await writer.write(text, in: field, target: target)
    }
}

/// A paste write's Accessibility calls on its registered field, each on `AXQueue`.
struct AXPasteTarget: PasteTarget {
    let queue: AXQueue
    let observer: FieldObserver
    let field: FieldID
    let range: TextRange
    let original: ExpectedText
    let replacement: String

    private var revised: ExpectedText {
        TextAccessRules.applying(replacement, at: range, to: original)
    }

    var changesText: Bool {
        TextAccessRules.text(of: original, at: range) != replacement
    }

    func state() async -> QuietPeriod.Read {
        await queue.run { [observer, field] in
            guard let reader = observer.entry(field)?.source else { return .unreadable }
            return QuietPeriod.read(length: reader.length(), text: { reader.string(for: $0) }, selection: { reader.selection() })
        }
    }

    func select() async -> (start: PastePlan.SelectionStart, user: TextRange?) {
        await queue.run { [observer, field, range, original] in
            guard let entry = observer.entry(field), let pid = entry.element.pid else { return (.refused(.otherField), nil) }
            guard AXElement.focusedApplicationPID() == pid else { return (.refused(.notFrontmost), nil) }
            guard observer.isFocusedElement(entry, pid: pid) else { return (.refused(.otherField), nil) }
            let reader = entry.source
            guard TextAccessRules.paragraphUnchanged(original, read: { reader.string(for: $0) }, length: { reader.length() }) else {
                return (.refused(.paragraphChanged), nil)
            }
            let user = reader.selection()
            switch reader.attemptSelect(range) {
            case .accepted: return (.requested, user)
            case .rejected: return (.rejected, user)
            case .unreachable: return (.unreachable, user)
            }
        }
    }

    func covers() async -> Bool {
        await queue.run { [observer, field] in observer.entry(field).map { covers($0.source) } ?? false }
    }

    /// One `AXQueue` job, so no queued callback or read runs between the last check and ⌘V.
    func recheckAndPost(keyCode: CGKeyCode) async -> PastePlan.RecheckPost {
        await queue.run { [observer, field] in
            guard let entry = observer.entry(field), let pid = entry.element.pid else { return .mismatch(.otherField) }
            guard AXElement.focusedApplicationPID() == pid else { return .mismatch(.notFrontmost) }
            guard observer.isFocusedElement(entry, pid: pid) else { return .mismatch(.otherField) }
            guard covers(entry.source) else { return .mismatch(.selectionMoved) }
            return .posted(CommandV.post(to: pid, keyCode: keyCode))
        }
    }

    func read() async -> PastePlan.Read {
        await queue.run { [observer, field, original, revised] in
            guard let reader = observer.entry(field)?.source else { return .unreadable }
            return TextAccessRules.pasteRead(original: original, revised: revised, read: { reader.string(for: $0) }, length: { reader.length() })
        }
    }

    func restoreCaret(_ end: WriteEnd, user: TextRange?) async {
        await queue.run { [observer, field, range, replacement] in
            guard let user, let entry = observer.entry(field) else { return }
            let reader = entry.source
            let target = TextAccessRules.pasteCaret(
                user: user, replaced: range, replacementLength: replacement.utf16.count, end: end,
                current: reader.selection(), stillFocused: observer.isFocused(entry)
            )
            if let target { _ = reader.select(target) }
        }
    }

    private func covers(_ reader: any FieldReader) -> Bool {
        guard let text = TextAccessRules.text(of: original, at: range) else { return false }
        return TextAccessRules.selectionCovers(range, text: text, selection: reader.selection(), selectedText: reader.selectedText())
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

    /// Focus can come back without an event (the same field refocused in an app that stayed active), so the
    /// deadline asks once more before giving up.
    func wait(for field: FieldID, timeout: Duration, isFocusedNow: @escaping @Sendable () async -> Bool) async -> Bool {
        let id = UUID()
        lock.withLock { waiters[id] = Waiter(field: field) }
        if await isFocusedNow() { resolve(id, true) }
        let timer = Task { [sleep] in
            do { try await sleep(timeout) } catch { return }
            self.resolve(id, await isFocusedNow())
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
