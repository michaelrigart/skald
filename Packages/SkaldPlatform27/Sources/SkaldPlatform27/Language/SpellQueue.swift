import Dispatch

final class SpellQueue: Sendable {
    static let shared = SpellQueue()

    private let queue = DispatchQueue(label: "com.michaelrigart.skald.spelling")

    init() {}

    func run<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    func enqueue(_ body: @Sendable @escaping () -> Void) {
        queue.async(execute: body)
    }
}
