import Foundation

/// A manual clock: time moves only on `advance(by:)`, which wakes every sleeper whose deadline has come.
final class TestClock: Clock, @unchecked Sendable { // reason: all state is guarded by a lock
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepCalls = 0
    private var callWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (immediate, waiters) = lock.withLock { () -> (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) in
                    sleepCalls += 1
                    let waiters = takeCallWaiters()
                    if Task.isCancelled { return (.failure(CancellationError()), waiters) }
                    if deadline <= current { return (.success(()), waiters) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return (nil, waiters)
                }
                waiters.forEach { $0.resume() }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.value.deadline <= current }
            due.keys.forEach { sleepers[$0] = nil }
            return Array(due.values)
        }
        due.forEach { $0.continuation.resume() }
    }

    /// Returns once `sleep` has been called `count` times in all, or when the waiting task is cancelled.
    func waitForSleepCalls(_ count: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if sleepCalls >= count || Task.isCancelled { return true }
                    callWaiters[id] = (count, continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { callWaiters.removeValue(forKey: id) }
            waiter?.continuation.resume()
        }
    }

    private func takeCallWaiters() -> [CheckedContinuation<Void, Never>] {
        let ready = callWaiters.filter { $0.value.count <= sleepCalls }
        ready.keys.forEach { callWaiters[$0] = nil }
        return ready.values.map(\.continuation)
    }
}
