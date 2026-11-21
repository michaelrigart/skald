import Foundation

/// Counts a fake's calls and, while closed, holds each call until the test releases it.
/// The owning actor keeps it as stored state, so every change happens on that actor.
struct CallGate {
    private var isClosed: Bool
    private(set) var arrivals = 0
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    init(closed: Bool) {
        isClosed = closed
    }

    /// Records a call and returns its index.
    mutating func arrive() -> Int {
        let index = arrivals
        arrivals += 1
        for (id, waiter) in waiters where waiter.count <= arrivals {
            waiters[id] = nil
            waiter.continuation.resume()
        }
        return index
    }

    func mustWait(_ index: Int) -> Bool {
        isClosed && !released.contains(index)
    }

    mutating func hold(_ index: Int, _ continuation: CheckedContinuation<Void, Never>) {
        held[index] = continuation
    }

    /// Resumes the continuation once `count` calls have arrived, or at once when the waiting task is cancelled.
    mutating func wait(_ id: UUID, for count: Int, _ continuation: CheckedContinuation<Void, Never>) {
        if arrivals >= count || Task.isCancelled {
            continuation.resume()
        } else {
            waiters[id] = (count, continuation)
        }
    }

    mutating func stopWaiting(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }

    mutating func release(_ index: Int) {
        released.insert(index)
        held.removeValue(forKey: index)?.resume()
    }

    mutating func open() {
        isClosed = false
        let waiting = held.values
        held = [:]
        waiting.forEach { $0.resume() }
    }
}
