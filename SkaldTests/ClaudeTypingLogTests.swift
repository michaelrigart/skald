import SkaldCore
import Testing
@testable import Skald

@Test func eachLineCountsARequestAndNamesItsOutcomeOnly() {
    #expect(ClaudeTypingLog.line(3, .answered) == "typing request 3: answered")
    #expect(ClaudeTypingLog.line(4, .failed(.keyRejected)) == "typing request 4: keyRejected")
    #expect(ClaudeTypingLog.line(5, .cancelled) == "typing request 5: cancelled")
    #expect(ClaudeTypingLog.line(6, .failed(.unreachable)) == "typing request 6: unreachable")
    #expect(ClaudeTypingLog.line(7, .failed(.rateLimited)) == "typing request 7: rateLimited")
    #expect(ClaudeTypingLog.line(8, .failed(.declined)) == "typing request 8: declined")
}

@Test func theLogCountsEveryRecordedRequest() {
    let log = ClaudeTypingLog()
    #expect(log.record(.answered) == 1)
    #expect(log.record(.failed(.unreachable)) == 2)
    #expect(log.record(.cancelled) == 3)
}
