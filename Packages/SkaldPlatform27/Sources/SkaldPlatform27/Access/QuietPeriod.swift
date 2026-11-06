import Foundation
import SkaldCore
import struct SkaldCore.TextRange

enum QuietPeriod {
    static let required: Duration = .milliseconds(1500)
    /// A field that keeps changing this long without a quiet interval is given up on.
    static let changingLimit: Duration = .seconds(10)

    static func remaining(
        now: ContinuousClock.Instant, lastKeystroke: ContinuousClock.Instant?, lastValueChange: ContinuousClock.Instant?
    ) -> Duration? {
        guard let last = [lastKeystroke, lastValueChange].compactMap({ $0 }).max() else { return nil }
        let elapsed = last.duration(to: now)
        return elapsed < required ? required - elapsed : nil
    }

    /// The whole field as the quiet interval compares it.
    struct State: Sendable, Equatable {
        let length: Int
        let text: String
        let selection: TextRange?
    }

    enum Read: Sendable, Equatable {
        case state(State)
        /// Longer than 20,000 units: the field can't be compared whole.
        case tooLong
        case unreadable
    }

    enum Outcome: Sendable, Equatable {
        case quiet(restarts: Int)
        case tooLong, unreadable, cancelled
        /// No quiet interval within 10 s of changes.
        case keptChanging
    }

    /// The field's state, read whole; a field over 20,000 units is never read.
    static func read(length: Int?, text: (TextRange) -> String?, selection: () -> TextRange?) -> Read {
        guard let length else { return .unreadable }
        guard length <= ReadWindow.limit else { return .tooLong }
        guard let whole = text(TextRange(location: 0, length: length)), whole.utf16.count == length else { return .unreadable }
        return .state(State(length: length, text: whole, selection: selection()))
    }

    /// The interval counts only when the field reads the same at both ends and no value change arrived in between:
    /// notifications can come up to 2 s late, so the comparison is the proof.
    static func holds(start: State, end: State, notified: Bool) -> Bool {
        !notified && start == end
    }
}

/// The injected clock, as offsets from when the writer was made.
struct PasteClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    init<C: Clock<Duration>>(_ clock: C) {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
    }
}

/// Value-change notifications per field, counted as they are delivered, for the quiet interval to wait on.
final class ValueChanges: @unchecked Sendable { // reason: counts and waiters are only touched under the lock
    private struct Waiter {
        let field: FieldID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var counts: [FieldID: Int] = [:]
    private var waiters: [UUID: Waiter] = [:]

    func count(_ field: FieldID) -> Int {
        lock.withLock { counts[field, default: 0] }
    }

    func changed(_ field: FieldID) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            counts[field, default: 0] += 1
            let due = waiters.filter { $0.value.field == field }
            due.keys.forEach { waiters[$0] = nil }
            return due.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    /// Returns once `field` has had more than `seen` changes, or when the waiting task is cancelled.
    func wait(for field: FieldID, after seen: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if counts[field, default: 0] > seen || Task.isCancelled { return true }
                    waiters[id] = Waiter(field: field, continuation: continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume()
        }
    }
}

/// Watches the whole field until it stays the same for 1.5 s on the injected clock. A value change restarts the
/// interval the moment it arrives; a change seen only in the state at the end restarts it from that read. A restart
/// 10 s or more after the watch began gives up.
struct QuietWatch: Sendable {
    private enum Wake {
        case elapsed, notified, cancelled
    }

    let field: FieldID
    let changes: ValueChanges
    let clock: PasteClock

    func run(read: @Sendable () async -> QuietPeriod.Read) async -> QuietPeriod.Outcome {
        var restarts = 0
        let began = clock.now()
        var seen = changes.count(field)
        let first = await read()
        guard case .state(var start) = first else { return Self.outcome(first) }
        while true {
            switch await wake(after: seen) {
            case .cancelled:
                return .cancelled
            case .notified:
                restarts += 1
                if clock.now() - began >= QuietPeriod.changingLimit { return .keptChanging }
                seen = changes.count(field)
                let restarted = await read()
                guard case .state(let state) = restarted else { return Self.outcome(restarted) }
                start = state
            case .elapsed:
                let beforeEnd = changes.count(field)
                let last = await read()
                guard case .state(let end) = last else { return Self.outcome(last) }
                if QuietPeriod.holds(start: start, end: end, notified: changes.count(field) != seen) { return .quiet(restarts: restarts) }
                restarts += 1
                if clock.now() - began >= QuietPeriod.changingLimit { return .keptChanging }
                seen = beforeEnd
                start = end
            }
        }
    }

    private static func outcome(_ read: QuietPeriod.Read) -> QuietPeriod.Outcome {
        read == .tooLong ? .tooLong : .unreadable
    }

    /// Whichever comes first: the end of the interval or a value change for the field.
    private func wake(after seen: Int) async -> Wake {
        let (changes, field, clock) = (changes, field, clock)
        let first = await withTaskGroup(of: Wake.self) { group in
            group.addTask {
                do {
                    try await clock.sleep(QuietPeriod.required)
                    return .elapsed
                } catch {
                    return .cancelled
                }
            }
            group.addTask {
                await changes.wait(for: field, after: seen)
                return .notified
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
        return Task.isCancelled ? .cancelled : first
    }
}
