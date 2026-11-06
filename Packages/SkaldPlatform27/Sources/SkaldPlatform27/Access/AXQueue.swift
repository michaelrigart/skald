import Dispatch
import Synchronization

public final class AXQueue: Sendable {
    /// Jobs started on any `AXQueue`, and text writes inside them, so a reader can keep what it read until
    /// the job ends or writes.
    private static let jobs = Atomic<Int>(0)

    private let queue = DispatchQueue(label: "com.michaelrigart.skald.accessibility")

    public init() {}

    /// The job running now, read from inside one; a text write inside the job moves it on.
    static var currentJob: Int {
        jobs.load(ordering: .relaxed)
    }

    /// A field's text was written: what a reader kept earlier in this job is stale.
    static func textWritten() {
        jobs.wrappingAdd(1, ordering: .relaxed)
    }

    public func run<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                Self.jobs.wrappingAdd(1, ordering: .relaxed)
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
            Self.jobs.wrappingAdd(1, ordering: .relaxed)
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
        let job = AXQueue.currentJob
        if let cached, cached.job == job { return cached.value }
        let value = read()
        cached = (job, value)
        return value
    }
}
