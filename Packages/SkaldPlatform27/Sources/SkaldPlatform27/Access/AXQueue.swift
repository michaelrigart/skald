import Dispatch
import Synchronization

public final class AXQueue: Sendable {
    /// The jobs started on one queue, and text writes inside them, so a reader can keep what it read until the
    /// job ends or writes. Each queue has its own, found from inside its jobs, so another queue's jobs never
    /// end this queue's.
    private final class Jobs: Sendable {
        let count = Atomic<Int>(0)
        let timeouts = Atomic<Int>(0)

        func next() {
            count.wrappingAdd(1, ordering: .relaxed)
        }
    }

    private static let jobsKey = DispatchSpecificKey<Jobs>()

    private let queue = DispatchQueue(label: "com.michaelrigart.skald.accessibility")
    private let jobs = Jobs()

    public init() {
        queue.setSpecific(key: Self.jobsKey, value: jobs)
    }

    /// The job running now on the queue this code runs on, read from inside one; a text write inside the job
    /// moves it on. Nil off any `AXQueue`.
    static var currentJob: Int? {
        DispatchQueue.getSpecific(key: jobsKey)?.count.load(ordering: .relaxed)
    }

    /// A field's text was written: what a reader kept earlier in this job is stale.
    static func textWritten() {
        DispatchQueue.getSpecific(key: jobsKey)?.next()
    }

    /// Accessibility calls that timed out on the queue this code runs on; 0 off any `AXQueue`.
    static var timeouts: Int {
        DispatchQueue.getSpecific(key: jobsKey)?.timeouts.load(ordering: .relaxed) ?? 0
    }

    static func timedOut() {
        DispatchQueue.getSpecific(key: jobsKey)?.timeouts.wrappingAdd(1, ordering: .relaxed)
    }

    public func run<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                self.jobs.next()
                continuation.resume(returning: body())
            }
        }
    }

    /// Runs `body` as one job when `isOn` still holds as the job starts, else answers `off`: a job queued behind
    /// others must not read or write in an app turned off while it waited.
    public func run<T: Sendable>(
        while isOn: @Sendable @escaping () -> Bool, otherwise off: T, _ body: @Sendable @escaping () -> T
    ) async -> T {
        await run { isOn() ? body() : off }
    }

    /// Runs `body` after everything already queued, in submission order; for callbacks that must not wait.
    public func enqueue(_ body: @Sendable @escaping () -> Void) {
        queue.async {
            self.jobs.next()
            body()
        }
    }
}

/// A value read at most once per `AXQueue` job; the next job reads it again. A read later in the same job
/// returns the earlier text, so a write through Accessibility calls `AXQueue.textWritten()` (as
/// `AXElement.setSelectedText` does) before anything reads back. Used on `AXQueue` only.
final class PerJob<Value>: @unchecked Sendable { // reason: only touched inside AXQueue jobs, which run one at a time
    private var cached: (job: Int, value: Value)?

    func value(_ read: () -> Value) -> Value {
        guard let job = AXQueue.currentJob else { return read() }
        if let cached, cached.job == job { return cached.value }
        let value = read()
        cached = (job, value)
        return value
    }
}
