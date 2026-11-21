import Testing
@testable import SkaldCore

struct ClaudeBackoffTests {
    @Test func failuresAreSortedByWhatTheyMean() {
        #expect(ClaudeTrouble(.timedOut) == .unreachable)
        #expect(ClaudeTrouble(.failed) == .unreachable)
        #expect(ClaudeTrouble(.unavailable(.claudeKeyRejected)) == .keyRejected)
        #expect(ClaudeTrouble(.unavailable(.claudeKeyMissing)) == .keyRejected)
        #expect(ClaudeTrouble(.unavailable(.claudeRateLimited)) == .rateLimited)
        #expect(ClaudeTrouble(.unavailable(.studioUnreachable)) == .unreachable)
        #expect(ClaudeTrouble(.refused) == .declined)
        #expect(ClaudeTrouble(.truncated) == .declined)
        #expect(ClaudeTrouble(.cancelled) == nil)
    }

    @Test func oneFailureFallsBackWithoutSuspending() {
        var backoff = ClaudeBackoff()
        backoff.failed(.unreachable, text: "a", at: .zero)
        #expect(!backoff.isSuspended(at: .zero))
        #expect(backoff.trouble == .unreachable)
        #expect(!backoff.mayAsk(about: "a", at: .seconds(1)))
        #expect(backoff.mayAsk(about: "b", at: .seconds(1)))
    }

    @Test func repeatedFailuresSuspendForAnIntervalThatDoublesToFiveMinutes() {
        var backoff = ClaudeBackoff()
        backoff.failed(.unreachable, text: "t1", at: .zero)
        backoff.failed(.unreachable, text: "t2", at: .seconds(1))
        #expect(backoff.isSuspended(at: .milliseconds(30_999)))
        #expect(!backoff.isSuspended(at: .seconds(31)))
        let steps: [(failureAt: Int, endsAt: Int)] = [
            (31, 91), (91, 211), (211, 451), (451, 751), (751, 1_051),
        ]
        for (index, step) in steps.enumerated() {
            backoff.failed(.unreachable, text: "t\(index + 3)", at: .seconds(step.failureAt))
            #expect(backoff.isSuspended(at: .seconds(step.endsAt) - .milliseconds(1)))
            #expect(!backoff.isSuspended(at: .seconds(step.endsAt)))
        }
    }

    @Test func aSuccessClearsTheSuspensionAndTheTroubleButNotTheFailedTexts() {
        var backoff = ClaudeBackoff()
        backoff.failed(.unreachable, text: "t1", at: .zero)
        backoff.failed(.unreachable, text: "t2", at: .seconds(1))
        backoff.succeeded()
        #expect(!backoff.isSuspended(at: .seconds(2)))
        #expect(backoff.trouble == nil)
        #expect(!backoff.mayAsk(about: "t1", at: .seconds(2)))
        #expect(backoff.mayAsk(about: "c", at: .seconds(2)))
        backoff.failed(.unreachable, text: "t3", at: .seconds(3))
        #expect(!backoff.isSuspended(at: .seconds(4)))
    }

    @Test func aDeclinedParagraphIsNotAskedAgainButSuspendsNothing() {
        var backoff = ClaudeBackoff()
        let texts = (1...5).map { "t\($0)" }
        for (index, text) in texts.enumerated() {
            backoff.failed(.declined, text: text, at: .seconds(index))
        }
        #expect(!backoff.isSuspended(at: .seconds(5)))
        #expect(backoff.trouble == .declined)
        for text in texts { #expect(!backoff.mayAsk(about: text, at: .seconds(5))) }
    }

    @Test func theFailedTextsAreTheLast32() {
        var backoff = ClaudeBackoff()
        for index in 0...32 { backoff.failed(.declined, text: "t\(index)", at: .seconds(index)) }
        #expect(backoff.mayAsk(about: "t0", at: .seconds(40)))
        #expect(!backoff.mayAsk(about: "t1", at: .seconds(40)))
    }
}
