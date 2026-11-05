enum QuietPeriod {
    static let required: Duration = .milliseconds(1500)

    static func remaining(
        now: ContinuousClock.Instant, lastKeystroke: ContinuousClock.Instant?, lastValueChange: ContinuousClock.Instant?
    ) -> Duration? {
        guard let last = [lastKeystroke, lastValueChange].compactMap({ $0 }).max() else { return nil }
        let elapsed = last.duration(to: now)
        return elapsed < required ? required - elapsed : nil
    }
}
