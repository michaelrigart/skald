import Testing
@testable import SkaldPlatform27

private let now = ContinuousClock.now

private func ago(_ milliseconds: Int) -> ContinuousClock.Instant {
    now.advanced(by: .milliseconds(-milliseconds))
}

@Test func aPasteWaitsForTheFullQuietPeriodAfterTheLastKeystrokeOrValueChange() {
    #expect(QuietPeriod.remaining(now: now, lastKeystroke: nil, lastValueChange: nil) == nil)
    #expect(QuietPeriod.remaining(now: now, lastKeystroke: ago(500), lastValueChange: nil) == .milliseconds(1000))
    #expect(QuietPeriod.remaining(now: now, lastKeystroke: nil, lastValueChange: ago(1000)) == .milliseconds(500))
}

@Test func theLaterOfTheKeystrokeAndTheValueChangeDecides() {
    #expect(QuietPeriod.remaining(now: now, lastKeystroke: ago(2000), lastValueChange: ago(1000)) == .milliseconds(500))
    #expect(QuietPeriod.remaining(now: now, lastKeystroke: ago(100), lastValueChange: ago(1400)) == .milliseconds(1400))
}

@Test func theQuietPeriodIsOverAtExactlyOneAndAHalfSeconds() {
    #expect(QuietPeriod.remaining(now: now, lastKeystroke: ago(1500), lastValueChange: ago(1600)) == nil)
    #expect(QuietPeriod.remaining(now: now, lastKeystroke: ago(1499), lastValueChange: nil) == .milliseconds(1))
    #expect(QuietPeriod.required == .milliseconds(1500))
}
