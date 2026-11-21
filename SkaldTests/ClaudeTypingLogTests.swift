import SkaldCore
import Testing
@testable import Skald

private struct StubEngine: Engine {
    let kind = EngineKind.claude
    let outcome: Result<String, EngineFailure>

    func run(_ r: EngineRequest) async throws(EngineFailure) -> String {
        try outcome.get()
    }
}

private let request = EngineRequest(action: .check, language: .nl, text: "Ik heb de fix nagekeken")

@Test func eachLineCountsARequestAndNamesItsOutcomeOnly() {
    #expect(ClaudeTypingLog.line(3, .success("Ik heb de fix nagekeken")) == "typing request 3: answered")
    #expect(ClaudeTypingLog.line(4, .failure(.unavailable(.claudeKeyRejected))) == "typing request 4: keyRejected")
    #expect(ClaudeTypingLog.line(5, .failure(.cancelled)) == "typing request 5: cancelled")
    #expect(ClaudeTypingLog.line(6, .failure(.timedOut)) == "typing request 6: unreachable")
    #expect(ClaudeTypingLog.line(7, .failure(.refused)) == "typing request 7: declined")
}

@Test func theLoggedEngineCountsEveryRequestAndAnswersAsTheInnerOne() async throws {
    let log = ClaudeTypingLog()
    let answering = LoggedEngine(StubEngine(outcome: .success("answer")), log: log)
    #expect(answering.kind == .claude)
    #expect(try await answering.run(request) == "answer")
    let failing = LoggedEngine(StubEngine(outcome: .failure(.timedOut)), log: log)
    await #expect(throws: EngineFailure.timedOut) { try await failing.run(request) }
    #expect(log.record(.success("")) == 3)
}
