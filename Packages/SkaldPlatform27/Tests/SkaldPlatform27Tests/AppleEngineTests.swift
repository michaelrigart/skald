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
    @Test("Guardrail and refusal errors are refused")
    func refusals() {
        #expect(AppleEngine.failure(for: LanguageModelError.guardrailViolation(.init(debugDescription: "test"))) == .refused)
        #expect(AppleEngine.failure(for: LanguageModelError.refusal(.init(explanation: "no", debugDescription: "test"))) == .refused)
    }

    @Test("An exceeded context size is truncated")
    func truncation() {
        let exceeded = LanguageModelError.ContextSizeExceeded(contextSize: 8192, tokenCount: 40061, debugDescription: "test")
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

    @Test("Unavailable model assets map to unavailable(modelNotReady)")
    func assetsUnavailable() {
        let error = SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "test"))
        #expect(AppleEngine.failure(for: error) == .unavailable(.modelNotReady))
    }

    @Test("Any other error maps to failed")
    func everythingElse() {
        #expect(AppleEngine.failure(for: LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "test"))) == .failed)
        let unsupported = LanguageModelError.UnsupportedLanguageOrLocale(languageCode: .english, debugDescription: "test")
        #expect(AppleEngine.failure(for: LanguageModelError.unsupportedLanguageOrLocale(unsupported)) == .failed)
        #expect(AppleEngine.failure(for: URLError(.badServerResponse)) == .failed)
    }
}

struct AppleEngineAnswerTests {
    @Test("Empty or whitespace-only output is a failure, never an applied result")
    func emptyOutput() {
        for output in ["", "   ", "\n\t\n"] {
            #expect(throws: EngineFailure.failed) { try AppleEngine.answer(output, input: "their is") }
        }
    }

    @Test("A wrapper the input did not have is stripped")
    func quoteWrapped() throws {
        #expect(try AppleEngine.answer("\"there is\"", input: "their is") == "there is")
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

    @Test("Cancelling the caller throws cancelled, even when the operation swallows the cancellation")
    func callerCancellation() async {
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let task = Task<EngineFailure?, Never> {
            do throws(EngineFailure) {
                _ = try await AppleEngine.race(timeout: .seconds(30)) {
                    signal.yield()
                    do { try await Task.sleep(for: .seconds(30)) } catch {}
                    return "swallowed"
                }
                return nil
            } catch {
                return error
            }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    @Test("An error thrown by the operation is mapped")
    func operationError() async {
        await #expect(throws: EngineFailure.refused) {
            try await AppleEngine.race(timeout: .seconds(30)) {
                throw LanguageModelError.guardrailViolation(.init(debugDescription: "test"))
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
