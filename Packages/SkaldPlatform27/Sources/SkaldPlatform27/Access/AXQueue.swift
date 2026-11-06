import Dispatch
import Synchronization

public final class AXQueue: Sendable {
    /// Jobs started on any `AXQueue`, so a reader can keep what it read for the rest of one job.
    private static let jobs = Atomic<Int>(0)

    private let queue = DispatchQueue(label: "com.michaelrigart.skald.accessibility")

    public init() {}

    /// The job running now, read from inside one.
    static var currentJob: Int {
        jobs.load(ordering: .relaxed)
    }

    public func run<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                Self.jobs.wrappingAdd(1, ordering: .relaxed)
                continuation.resume(returning: body())
            }
        }
    }

    /// Runs `body` after everything already queued, in submission order; for callbacks that must not wait.
    public func enqueue(_ body: @Sendable @escaping () -> Void) {
        queue.async {
            Self.jobs.wrappingAdd(1, ordering: .relaxed)
            body()
        }
    }
}

/// A value read at most once per `AXQueue` job; the next job reads it again. Used on `AXQueue` only.
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
