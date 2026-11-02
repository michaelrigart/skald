import Foundation
import FoundationModels
import SkaldCore
import Testing
@testable import SkaldPlatform27

private let en1 = "Hi Sarah, thanks for the quick reply. I've went through the logs and their is definitely something wrong with the backup job on the staging server."
private let en1Reference = "Hi Sarah, thanks for the quick reply. I've gone through the logs and there is definitely something wrong with the backup job on the staging server."
private let nl1 = "Hallo Jan, de back-up word elke nacht om twee uur uitgevoerd, maar gisteren is er iets fout gegaan."

struct AppleAvailabilityTests {
    @Test("Each unavailable reason maps to its own UnavailableReason; available maps to nil")
    func mapsReasons() {
        #expect(AppleAvailability.map(.available) == nil)
        #expect(AppleAvailability.map(.unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceOff)
        #expect(AppleAvailability.map(.unavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(AppleAvailability.map(.unavailable(.modelNotReady)) == .modelNotReady)
    }
}

struct AppleEngineFailureTests {
    private static let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")

    @Test("Guardrail and refusal errors, in both error families, are refused")
    func refusals() {
        let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
        #expect(AppleEngine.failure(for: LanguageModelSession.GenerationError.guardrailViolation(Self.context)) == .refused)
        #expect(AppleEngine.failure(for: LanguageModelSession.GenerationError.refusal(refusal, Self.context)) == .refused)
        #expect(AppleEngine.failure(for: LanguageModelError.guardrailViolation(.init(debugDescription: "test"))) == .refused)
        #expect(AppleEngine.failure(for: LanguageModelError.refusal(.init(explanation: "no", debugDescription: "test"))) == .refused)
    }

    @Test("An exceeded context window, in both error families, is truncated")
    func truncation() {
        #expect(AppleEngine.failure(for: LanguageModelSession.GenerationError.exceededContextWindowSize(Self.context)) == .truncated)
        let exceeded = LanguageModelError.ContextSizeExceeded(contextSize: 4096, tokenCount: 5000, debugDescription: "test")
        #expect(AppleEngine.failure(for: LanguageModelError.contextSizeExceeded(exceeded)) == .truncated)
    }

    @Test("Cancellation maps to cancelled")
    func cancellation() {
        #expect(AppleEngine.failure(for: CancellationError()) == .cancelled)
    }

    @Test("A model-side timeout maps to timedOut")
    func modelTimeout() {
        #expect(AppleEngine.failure(for: LanguageModelError.timeout(.init(debugDescription: "test"))) == .timedOut)
    }

    @Test("Any other error maps to failed")
    func everythingElse() {
        #expect(AppleEngine.failure(for: LanguageModelSession.GenerationError.assetsUnavailable(Self.context)) == .failed)
        #expect(AppleEngine.failure(for: LanguageModelSession.GenerationError.rateLimited(Self.context)) == .failed)
        #expect(AppleEngine.failure(for: LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "test"))) == .failed)
        #expect(AppleEngine.failure(for: URLError(.badServerResponse)) == .failed)
    }
}

struct AppleEngineRaceTests {
    @Test("An operation slower than the timeout throws timedOut")
    func slowOperationTimesOut() async {
        await #expect(throws: EngineFailure.timedOut) {
            try await AppleEngine.race(timeout: .milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
                return "late"
            }
        }
    }

    @Test("An operation faster than the timeout returns its result")
    func fastOperationWins() async throws {
        let result = try await AppleEngine.race(timeout: .seconds(30)) { "done" }
        #expect(result == "done")
    }

    @Test("Cancelling the caller throws cancelled, never timedOut")
    func callerCancellation() async {
        let task = Task<EngineFailure?, Never> {
            do throws(EngineFailure) {
                _ = try await AppleEngine.race(timeout: .seconds(30)) {
                    try await Task.sleep(for: .seconds(30))
                    return "late"
                }
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    @Test("An error thrown by the operation is mapped")
    func operationError() async {
        await #expect(throws: EngineFailure.refused) {
            try await AppleEngine.race(timeout: .seconds(30)) {
                throw LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "test"))
            }
        }
    }
}

struct AppleEngineOptionsTests {
    @Test("Confirm requests are capped at four tokens; every request is greedy")
    func options() {
        #expect(AppleEngine.options(for: .confirm) == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 4))
        for action in EngineAction.allCases where action != .confirm {
            #expect(AppleEngine.options(for: action) == GenerationOptions(samplingMode: .greedy))
        }
    }
}

private actor Recorder {
    private(set) var requests: [EngineRequest] = []

    func record(_ request: EngineRequest) {
        requests.append(request)
    }
}

private struct FakeEngine: Engine {
    let reply: Result<String, EngineFailure>
    let recorder = Recorder()

    var kind: EngineKind { .thisMac }

    func run(_ r: EngineRequest) async throws(EngineFailure) -> String {
        await recorder.record(r)
        return try reply.get()
    }
}

struct AppleConfirmerTests {
    private let edit = TextDiff.edits(from: "their is", to: "there is").first!

    private func verdict(_ reply: Result<String, EngineFailure>) async -> Bool? {
        await AppleConfirmer(engine: FakeEngine(reply: reply)).confirm(edit, in: "their is", language: .en)
    }

    @Test("A leading yes confirms, whatever its case or trailing punctuation")
    func yes() async {
        for reply in ["yes", "Yes", "YES.", " yes\n", "Yes, the change fixes it"] {
            #expect(await verdict(.success(reply)) == true, "reply: \(reply)")
        }
    }

    @Test("A leading no rejects, whatever its case or trailing punctuation")
    func no() async {
        for reply in ["no", "No", "NO.", " no\n", "No, it was already correct"] {
            #expect(await verdict(.success(reply)) == false, "reply: \(reply)")
        }
    }

    @Test("Anything else is no verdict")
    func unclear() async {
        for reply in ["maybe", "Yesterday", "Nope", "Not sure", "The change is yes", "ja"] {
            #expect(await verdict(.success(reply)) == nil, "reply: \(reply)")
        }
    }

    @Test("An engine failure is no verdict")
    func engineFailure() async {
        #expect(await verdict(.failure(.timedOut)) == nil)
        #expect(await verdict(.failure(.unavailable(.modelNotReady))) == nil)
    }

    @Test("The request carries the paragraph, language, original and replacement")
    func request() async throws {
        let engine = FakeEngine(reply: .success("yes"))
        _ = await AppleConfirmer(engine: engine).confirm(edit, in: "their is", language: .nl)
        let sent = try #require(await engine.recorder.requests.first)
        #expect(sent.action == .confirm)
        #expect(sent.language == .nl)
        #expect(sent.text == "their is")
        #expect(sent.confirmOriginal == edit.original)
        #expect(sent.confirmReplacement == edit.replacement)
    }
}

struct AppleEngineModelTests {
    @Test(
        "check/en on seed en1 returns the reference text",
        .tags(.requiresSystem),
        .enabled(if: SystemLanguageModel.default.isAvailable)
    )
    func englishCheck() async throws {
        let output = try await AppleEngine().run(EngineRequest(action: .check, language: .en, text: en1))
        #expect(output == en1Reference)
    }

    @Test(
        "check/nl on seed nl1 fixes word to wordt",
        .tags(.requiresSystem),
        .enabled(if: SystemLanguageModel.default.isAvailable)
    )
    func dutchCheck() async throws {
        let output = try await AppleEngine().run(EngineRequest(action: .check, language: .nl, text: nl1))
        #expect(output.contains("wordt"))
    }
}
