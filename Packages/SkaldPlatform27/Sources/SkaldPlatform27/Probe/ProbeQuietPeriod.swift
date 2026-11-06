extension QuietPeriod {
    /// The probe's quiet period before its paste: what is left of it after the last keystroke or value change.
    static func remaining(
        now: ContinuousClock.Instant, lastKeystroke: ContinuousClock.Instant?, lastValueChange: ContinuousClock.Instant?
    ) -> Duration? {
        guard let last = [lastKeystroke, lastValueChange].compactMap({ $0 }).max() else { return nil }
        let elapsed = last.duration(to: now)
        return elapsed < required ? required - elapsed : nil
    }
}
