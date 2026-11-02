import Foundation
import FoundationModels
import SkaldCore

public struct AppleEngine: Engine {
    private let timeout: Duration

    public var kind: EngineKind { .thisMac }

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    public func run(_ r: EngineRequest) async throws(EngineFailure) -> String {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        if let reason = AppleAvailability.map(model.availability) { throw .unavailable(reason) }
        let instructions = Prompts.instructions(r.action, r.language)
        let prompt = Prompts.prompt(r)
        let options = Self.options(for: r.action)
        let text = try await Self.race(timeout: timeout) {
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: prompt, options: options).content
        }
        let cleaned = OutputCleaner.clean(text, input: r.text)
        guard !cleaned.isEmpty else { throw .failed }
        return cleaned
    }

    static func options(for action: EngineAction) -> GenerationOptions {
        action == .confirm
            ? GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 4)
            : GenerationOptions(samplingMode: .greedy)
    }

    static func race(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> String
    ) async throws(EngineFailure) -> String {
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let text = first else { throw TimedOut() }
                return text
            }
        } catch {
            throw failure(for: error)
        }
    }

    static func failure(for error: any Error) -> EngineFailure {
        switch error {
        case is CancellationError: .cancelled
        case is TimedOut: .timedOut
        case let error as LanguageModelError: failure(for: error)
        case let error as LanguageModelSession.GenerationError: failure(for: error)
        default: .failed
        }
    }

    private static func failure(for error: LanguageModelError) -> EngineFailure {
        switch error {
        case .guardrailViolation, .refusal: .refused
        case .contextSizeExceeded: .truncated
        case .timeout: .timedOut
        default: .failed
        }
    }

    private static func failure(for error: LanguageModelSession.GenerationError) -> EngineFailure {
        switch error {
        case .guardrailViolation, .refusal: .refused
        case .exceededContextWindowSize: .truncated
        default: .failed
        }
    }

    private struct TimedOut: Error {}
}

public struct AppleConfirmer: EditConfirming {
    private let engine: any Engine

    public init(engine: any Engine = AppleEngine()) {
        self.engine = engine
    }

    public func confirm(_ edit: Edit, in paragraph: String, language: Language) async -> Bool? {
        let request = EngineRequest(
            action: .confirm,
            language: language,
            text: paragraph,
            confirmOriginal: edit.original,
            confirmReplacement: edit.replacement
        )
        guard let reply = try? await engine.run(request) else { return nil }
        switch reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(while: \.isLetter) {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }
}
