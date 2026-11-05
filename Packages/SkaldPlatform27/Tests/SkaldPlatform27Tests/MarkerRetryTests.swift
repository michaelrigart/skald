import Testing
@testable import SkaldPlatform27

@Test func theMarkerRetryGivesUpAfterFiveAttemptsAndReportsASuccess() {
    #expect(MarkerRetry.step(attempts: 0, containsMarker: false, placed: false) == .idle)
    #expect(MarkerRetry.step(attempts: 0, containsMarker: true, placed: true) == .idle)
    #expect(MarkerRetry.step(attempts: 0, containsMarker: true, placed: false) == .retry(1))
    #expect(MarkerRetry.step(attempts: 4, containsMarker: true, placed: false) == .retry(5))
    #expect(MarkerRetry.step(attempts: 5, containsMarker: true, placed: false) == .gaveUp(attempts: 5))
    #expect(MarkerRetry.step(attempts: 3, containsMarker: true, placed: true) == .placed(afterAttempts: 3))
    #expect(MarkerRetry.step(attempts: 2, containsMarker: false, placed: false) == .idle)
    #expect(MarkerRetry.maxAttempts == 5)
    #expect(MarkerRetry.interval == .milliseconds(300))
}
