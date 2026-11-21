import Foundation
@testable import SkaldCore
import SkaldCoreTestSupport
import struct SkaldCore.Issue

struct PipelineRig {
    static let fieldA = FieldID(app: "com.example.mail", token: "a")
    static let fieldB = FieldID(app: "com.example.mail", token: "b")
    static let pause = Duration.milliseconds(700)

    static func makeSettings(typing: Bool = true, model: Bool = true, neverTouch: [String] = []) -> Settings {
        var settings = Settings()
        settings.typingChecks = [.en: typing, .nl: typing, .fr: typing]
        settings.modelChecks = [.en: model, .nl: model, .fr: model]
        neverTouch.forEach { settings.addNeverTouch($0) }
        return settings
    }

    static func engineRouter(_ settings: Settings, apple: UnavailableReason? = nil, key: Bool = false) -> EngineRouter {
        EngineRouter(settings: settings, appleAvailability: apple, thermalPaused: false, claudeKeyPresent: key)
    }

    final class ModelLog: @unchecked Sendable { // reason: the list is only touched under the lock
        private let lock = NSLock()
        private var asked: [String] = []

        var models: [String] { lock.withLock { asked } }

        func record(_ model: String) {
            lock.withLock { asked.append(model) }
        }
    }

    final class OutcomeLog: @unchecked Sendable { // reason: the list is only touched under the lock
        private let lock = NSLock()
        private var seen: [ClaudeOutcome] = []

        var outcomes: [ClaudeOutcome] { lock.withLock { seen } }

        func record(_ outcome: ClaudeOutcome) {
            lock.withLock { seen.append(outcome) }
        }
    }

    static func next(
        _ iterator: inout AsyncStream<IssueSnapshot>.Iterator,
        where matches: (IssueSnapshot) -> Bool
    ) async -> IssueSnapshot? {
        while let snapshot = await iterator.next() {
            if matches(snapshot) { return snapshot }
        }
        return nil
    }

    actor GatedOracle: WordOracle {
        private let inner: FakeWordOracle
        private var gate: CallGate

        init(misspelled: Set<String>, gated: Bool) {
            let entries = Dictionary(uniqueKeysWithValues: misspelled.map {
                ($0, FakeWordOracle.Entry(misspelled: true, english: false, stem: nil, lemma: nil, function: nil))
            })
            inner = FakeWordOracle(dictionary: ["en": entries, "nl": entries, "fr": entries])
            gate = CallGate(closed: gated)
        }

        func facts(for words: Set<String>, language: Language) async -> WordFacts {
            let index = gate.arrive()
            if gate.mustWait(index) {
                await withCheckedContinuation { gate.hold(index, $0) }
            }
            return await inner.facts(for: words, language: language)
        }

        func waitForCalls(_ count: Int) async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { gate.wait(id, for: count, $0) }
            } onCancel: {
                Task { await self.stopWaiting(id) }
            }
        }

        private func stopWaiting(_ id: UUID) {
            gate.stopWaiting(id)
        }

        func release(_ index: Int) {
            gate.release(index)
        }

        func open() {
            gate.open()
        }
    }

    actor RecordingConfirmer: EditConfirming {
        private(set) var asked: [String] = []

        func confirm(_ edit: Edit, in paragraph: String, language: Language) -> Bool? {
            asked.append(edit.original)
            return true
        }
    }

    let access = FakeTextAccess()
    let engine: FakeEngine
    let claude: (any Engine)?
    let claudeModels = ModelLog()
    let claudeOutcomes = OutcomeLog()
    let key: Bool
    let spelling: FakeSpelling
    let oracle: GatedOracle
    let confirmer = RecordingConfirmer()
    let clock = TestClock()
    let router: LiveRouter
    let pipeline: CheckPipeline

    init(
        _ settings: Settings,
        engine: FakeEngine = .correcting(["teh": "the"]),
        claude: (any Engine)? = nil,
        key: Bool = false,
        onClaudeFactory: (@Sendable () -> Void)? = nil,
        showClaude: (@Sendable (ClaudeStatus) async -> Void)? = nil,
        misspellings: [String: String] = ["teh": "the"],
        oracleGated: Bool = false,
        detector: any LanguageDetecting = FakeLanguageDetector()
    ) {
        self.engine = engine
        self.claude = claude
        self.key = key
        spelling = FakeSpelling(misspellings)
        oracle = GatedOracle(misspelled: Set(misspellings.keys.map { $0.lowercased() }), gated: oracleGated)
        router = LiveRouter(Self.engineRouter(settings, key: key))
        let models = claudeModels
        let outcomes = claudeOutcomes
        let factory: (@Sendable (String) -> any Engine)? = claude.map { engine in
            { @Sendable model in
                models.record(model)
                onClaudeFactory?()
                return engine
            }
        }
        pipeline = CheckPipeline(
            access: access,
            apple: engine,
            claude: factory,
            onClaudeRequest: { outcomes.record($0) },
            showClaude: showClaude,
            spelling: spelling,
            detector: detector,
            oracle: oracle,
            confirmer: confirmer,
            clock: clock,
            settings: settings,
            router: router
        )
    }

    func focus(_ text: String, caret: Int = 0, in field: FieldID = fieldA) async {
        await access.set(text, caret: caret, in: field)
        await pipeline.receive(.focused(field))
    }

    /// Lets the typing pause run out; the timer's read and the checks it starts may still be running.
    func pass() {
        clock.advance(by: Self.pause)
    }

    /// Moves the caret, lets the pause run out and waits for every check it starts.
    func recheckAtCaret() async {
        await pipeline.receive(.caretMoved(Self.fieldA))
        pass()
        await pipeline.drain()
    }

    func check() async {
        pass()
        await pipeline.drain()
    }

    func visible(in field: FieldID = Self.fieldA) async -> [Issue] {
        await pipeline.tracker.visible(in: field)
    }

    func modelIssues() async -> [Issue] {
        await visible().filter { $0.source == .model }
    }

    func update(_ settings: Settings, apple: UnavailableReason? = nil) async {
        await router.set(Self.engineRouter(settings, apple: apple, key: key))
        await pipeline.update(settings: settings)
    }
}
