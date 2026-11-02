import Dispatch

public final class AXQueue: Sendable {
    private let queue = DispatchQueue(label: "com.michaelrigart.skald.accessibility")

    public init() {}

    public func run<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
