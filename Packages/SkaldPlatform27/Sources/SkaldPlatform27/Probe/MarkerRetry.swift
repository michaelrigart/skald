#if DEBUG
enum MarkerRetry {
    static let maxAttempts = 5
    static let interval: Duration = .milliseconds(300)

    enum Step: Equatable {
        case idle
        case retry(Int)
        case placed(afterAttempts: Int)
        case gaveUp(attempts: Int)
    }

    static func step(attempts: Int, containsMarker: Bool, placed: Bool) -> Step {
        if placed { return attempts > 0 ? .placed(afterAttempts: attempts) : .idle }
        guard containsMarker else { return .idle }
        return attempts < maxAttempts ? .retry(attempts + 1) : .gaveUp(attempts: attempts)
    }
}
#endif
