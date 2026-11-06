import Foundation

public struct IssueSnapshot: Sendable, Equatable {
    public let field: FieldID?
    public let issues: [Issue]

    public init(field: FieldID?, issues: [Issue]) {
        self.field = field
        self.issues = issues
    }
}

/// Turns field events into published issues: drives the scheduler on the injected clock, runs spelling and
/// model checks by route, and publishes only results whose epoch, generation, paragraph and route still hold.
public actor CheckPipeline {
    private struct Timing: Sendable {
        let elapsed: @Sendable () -> Duration
        let sleep: @Sendable (Duration) async throws -> Void

        static func starting<C: Clock<Duration>>(now clock: C) -> Timing {
            let origin = clock.now
            return Timing(
                elapsed: { origin.duration(to: clock.now) },
                sleep: { try await clock.sleep(until: origin.advanced(by: $0), tolerance: nil) }
            )
        }
    }

    private struct Timer {
        let token: Int
        let deadline: Duration
        let task: Task<Void, Never>
    }

    private enum ModelOutcome {
        /// The engine answered and the answer was judged: the paragraph counts as checked.
        case checked
        /// Cancelled, failed, stale or no longer routed to the model: the next pause runs it again.
        case dropped
    }

    public nonisolated let issues: AsyncStream<IssueSnapshot>
    private let publisher: AsyncStream<IssueSnapshot>.Continuation
    private let access: any TextAccess
    private let apple: any Engine
    private let spelling: any SpellingChecking
    private let detector: any LanguageDetecting
    private let oracle: any WordOracle
    private let confirmer: (any EditConfirming)?
    private let clock: any Clock<Duration>
    private let router: LiveRouter

    private var settings: Settings
    private var editGuard: EditGuard
    private var scheduler = CheckScheduler()
    private(set) var tracker = IssueTracker()
    private(set) var lastPublished = IssueSnapshot(field: nil, issues: [])
    private var timing: Timing
    private var events: Task<Void, Never>?
    private var timer: Timer?
    private var lastToken = 0
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var spellingJobs: [ParagraphKey: UUID] = [:]
    /// A generation is current while it is here. Its job reports how it ended; a generation the scheduler
    /// cancels is removed without a report, since the scheduler has already let it go.
    private var modelJobs: [Int: Task<Void, Never>] = [:]
    private var epoch = 0
    /// Advanced by every field event the scheduler acts on and every lifecycle change: pause, resume, update and
    /// recheck. A read keeps its answer only while the revision it started at is current.
    private var readRevision = 0
    private var readsInFlight = 0
    private var isPaused = false
    private var currentField: FieldID?
    private var fieldLanguages = FieldLanguages()
    private var latest: FieldSnapshot?
    private var appleUnavailable: UnavailableReason?

    public init(
        access: any TextAccess,
        apple: any Engine,
        spelling: any SpellingChecking,
        detector: any LanguageDetecting,
        oracle: any WordOracle,
        confirmer: (any EditConfirming)?,
        clock: any Clock<Duration>,
        settings: Settings,
        router: LiveRouter
    ) {
        (issues, publisher) = AsyncStream.makeStream(of: IssueSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        self.access = access
        self.apple = apple
        self.spelling = spelling
        self.detector = detector
        self.oracle = oracle
        self.confirmer = confirmer
        self.clock = clock
        self.settings = settings
        self.router = router
        editGuard = EditGuard(neverTouch: Set(settings.neverTouch))
        timing = Timing.starting(now: clock)
    }

    deinit {
        events?.cancel()
        publisher.finish()
    }

    public func start() {
        guard events == nil else { return }
        let clock = self.clock
        timing = Timing.starting(now: clock)
        let stream = access.events
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.receive(event)
            }
        }
    }

    public func setPaused(_ p: Bool) {
        guard p != isPaused else { return }
        isPaused = p
        epoch += 1
        readRevision += 1
        send(p ? .paused : .resumed)
    }

    /// Call after the `LiveRouter` holds the router for these settings. The new epoch dooms every check in
    /// flight. When some were running, the field is focused again in the scheduler: that cancels the running
    /// model check without starting the next chunk, lets spelling run again and checks after the pause.
    public func update(settings new: Settings) {
        let switchesChanged = new.typingChecks != settings.typingChecks || new.modelChecks != settings.modelChecks
        let discarded = !spellingJobs.isEmpty || !modelJobs.isEmpty
        settings = new
        editGuard = EditGuard(neverTouch: Set(new.neverTouch))
        appleUnavailable = nil
        epoch += 1
        readRevision += 1
        if switchesChanged {
            send(.recheck)
        } else if discarded, let currentField {
            send(.field(.focused(currentField)))
        } else if readsInFlight > 0 {
            send(.reread)
        }
        let touching = tracker.removeAll { editGuard.touchesNeverTouch($0.edit, in: $0.chunk.text) }
        if !touching.isEmpty { send(.forget(touching)) }
        publish()
    }

    /// The field's last confident language, kept for the newest fields across focus changes; the panel's
    /// paragraphs too short to detect inherit it.
    public func lastConfidentLanguage(for field: FieldID) -> Language? {
        fieldLanguages[field]
    }

    public func accept(_ id: UUID) async -> ReplaceOutcome {
        guard let issue = tracker.issue(id), !issue.edit.writeText.isEmpty else { return .failed }
        let write = issue.edit.writeRange
        let outcome = await access.replace(
            TextRange(location: issue.chunk.range.location + write.location, length: write.length),
            expected: issue.expected,
            with: issue.edit.writeText,
            in: issue.key.field
        )
        tracker.removeAll { $0.id == id }
        publish()
        return outcome
    }

    public func ignore(_ id: UUID) {
        tracker.ignore(id)
        publish()
    }

    /// Returns the issue's word after removing every issue on it; the caller adds it to the never-touch list.
    public func neverFlag(_ id: UUID) -> String? {
        guard let word = tracker.issue(id)?.word else { return nil }
        let dropped = tracker.removeAll(word: word)
        if !dropped.isEmpty { send(.forget(dropped)) }
        publish()
        return word
    }

    // MARK: Events, and the hooks tests drive directly

    func receive(_ event: FieldEvent) {
        switch event {
        case .focused(let field):
            currentField = field
            epoch += 1
            readRevision += 1
        case .edited(let field), .caretMoved(let field):
            if field == currentField { readRevision += 1 }
        }
        send(.field(event))
    }

    /// Waits until no job is running and no due timer is left to fire.
    func drain() async {
        while !Task.isCancelled {
            if let timer, timer.deadline <= timing.elapsed() {
                await timer.task.value
            } else if let job = jobs.values.first {
                await job.value
            } else {
                return
            }
        }
    }

    // MARK: Scheduler

    private func send(_ event: SchedulerEvent) {
        for effect in scheduler.handle(event, at: timing.elapsed()) {
            apply(effect)
        }
        publish()
    }

    private func apply(_ effect: SchedulerEffect) {
        switch effect {
        case .armTimer(let deadline):
            arm(deadline)
        case .disarmTimer:
            timer?.task.cancel()
            timer = nil
        case .read(let field):
            track { await $0.read(field) }
        case .suspendIssues(let field):
            tracker.suspend(field)
        case .revalidate(let snapshot):
            latest = snapshot
            let dropped = tracker.revalidate(snapshot)
            if !dropped.isEmpty { send(.forget(dropped)) }
        case .clearIssues:
            tracker.clear()
        case .checkSpelling(let key, let chunk, let parent):
            startSpelling(key, chunk: chunk, parent: parent)
        case .checkModel(let key, let chunk, let parent, let generation):
            startModel(key, chunk: chunk, parent: parent, generation: generation)
        case .cancelModel(let generation):
            modelJobs.removeValue(forKey: generation)?.cancel()
        }
    }

    private func arm(_ deadline: Duration) {
        timer?.task.cancel()
        lastToken += 1
        let token = lastToken
        let sleep = timing.sleep
        let task = Task { [weak self] in
            let fired = (try? await sleep(deadline)) != nil
            await self?.timerEnded(token, fired: fired)
        }
        timer = Timer(token: token, deadline: deadline, task: task)
    }

    private func timerEnded(_ token: Int, fired: Bool) {
        guard timer?.token == token else { return }
        timer = nil
        if fired { send(.timerFired) }
    }

    @discardableResult
    private func track(_ id: UUID = UUID(), _ job: @escaping @Sendable (isolated CheckPipeline) async -> Void) -> Task<Void, Never> {
        let task = Task {
            await job(self)
            self.jobs[id] = nil
        }
        jobs[id] = task
        return task
    }

    /// A snapshot taken before a newer field event or lifecycle change is stale: that change scheduled its own read.
    private func read(_ field: FieldID) async {
        let revision = readRevision
        readsInFlight += 1
        let snapshot = await access.snapshot(of: field)
        readsInFlight -= 1
        guard let snapshot, revision == readRevision else { return }
        send(.snapshot(snapshot))
    }

    // MARK: Spelling

    private func startSpelling(_ key: ParagraphKey, chunk: Paragraph, parent: Paragraph) {
        guard let language = detectLanguage(of: parent, in: key.field) else { return send(.forget([key])) }
        let epoch = self.epoch
        let id = UUID()
        spellingJobs[key] = id
        track(id) { pipeline in
            await pipeline.spell(key, chunk: chunk, language: language, epoch: epoch)
            if pipeline.spellingJobs[key] == id { pipeline.spellingJobs[key] = nil }
        }
    }

    private func spell(_ key: ParagraphKey, chunk: Paragraph, language: Language, epoch: Int) async {
        guard await route(language) != .off else {
            if epoch == self.epoch { tracker.clear(key) }
            return send(.forget([key]))
        }
        let flags = await spelling.flags(in: chunk, language: language, neverTouch: Set(settings.neverTouch))
        let editGuard = self.editGuard
        let kept = await editGuard.resolve(flags, in: chunk.text, language: language, source: .spelling, oracle: oracle, confirmer: nil)
        guard epoch == self.epoch, await route(language) != .off, epoch == self.epoch,
              let issues = anchored(kept, key: key, source: .spelling, language: language)
        else { return send(.forget([key])) }
        tracker.setSpelling(issues, for: key)
        publish()
    }

    // MARK: Model

    private func startModel(_ key: ParagraphKey, chunk: Paragraph, parent: Paragraph, generation: Int) {
        guard let language = detectLanguage(of: parent, in: key.field) else { return send(.modelFailed(generation: generation)) }
        let epoch = self.epoch
        let spellingJob = spellingJobs[key].flatMap { jobs[$0] }
        let task = track { pipeline in
            await spellingJob?.value
            let outcome = await pipeline.checkModel(key, chunk: chunk, language: language, generation: generation, epoch: epoch)
            pipeline.finishModel(generation, outcome)
        }
        modelJobs[generation] = task
    }

    private func checkModel(_ key: ParagraphKey, chunk: Paragraph, language: Language, generation: Int, epoch: Int) async -> ModelOutcome {
        guard isCurrent(epoch, generation), await route(language) == .model, isCurrent(epoch, generation) else { return .dropped }
        let output: String
        do {
            output = try await apple.run(EngineRequest(action: .check, language: language, text: chunk.text))
        } catch {
            if case .unavailable(let reason) = error, epoch == self.epoch { appleUnavailable = reason }
            return .dropped
        }
        guard isCurrent(epoch, generation) else { return .dropped }

        let answer = await ModelAnswer.judge(
            output, for: chunk.text, language: language, editGuard: editGuard, detector: detector, oracle: oracle, confirmer: confirmer
        ) { [weak self] language in
            await self?.mayConfirm(language, epoch: epoch, generation: generation) ?? false
        }
        let kept: [Edit]? = if case .kept(let edits) = answer { edits } else { nil }
        guard isCurrent(epoch, generation), await route(language) == .model, isCurrent(epoch, generation),
              let issues = anchored(kept ?? [], key: key, source: .model, language: language)
        else { return .dropped }
        guard kept != nil else { return .checked }
        tracker.setModel(issues, for: key)
        publish()
        return .checked
    }

    private func finishModel(_ generation: Int, _ outcome: ModelOutcome) {
        guard modelJobs.removeValue(forKey: generation) != nil else { return }
        switch outcome {
        case .checked: send(.modelFinished(generation: generation))
        case .dropped: send(.modelFailed(generation: generation))
        }
    }

    private func isCurrent(_ epoch: Int, _ generation: Int) -> Bool {
        epoch == self.epoch && modelJobs[generation] != nil && !Task.isCancelled
    }

    private func mayConfirm(_ language: Language, epoch: Int, generation: Int) async -> Bool {
        guard isCurrent(epoch, generation), await router.modelAllowed(language) else { return false }
        return appleUnavailable == nil && isCurrent(epoch, generation)
    }

    // MARK: Routing and publication

    private func route(_ language: Language) async -> TypingRoute {
        let route = await router.current.typing(language)
        if route == .model, let appleUnavailable { return .spellingOnly(appleUnavailable) }
        return route
    }

    /// A paragraph too short to detect inherits the field's last confident language; a field without one yet
    /// (just focused, or Skald just relaunched) takes the language of the text read around the paragraph.
    private func detectLanguage(of paragraph: Paragraph, in field: FieldID) -> Language? {
        let language = detector.detect(paragraph.text, previous: fieldLanguages[field])
            ?? latest.flatMap { $0.field == field ? detector.detect($0.text, previous: nil) : nil }
        if let language { fieldLanguages[field] = language }
        return language
    }

    /// Anchors kept edits to the key's paragraph in the latest snapshot, or returns nil when it is gone.
    private func anchored(_ edits: [Edit], key: ParagraphKey, source: IssueSource, language: Language) -> [Issue]? {
        guard let latest, let (parent, chunk) = ParagraphKeys.locate(key, in: ParagraphKeys.parents(in: latest)) else { return nil }
        return edits
            .filter { !editGuard.touchesNeverTouch($0, in: chunk.text) }
            .map { Issue(key: key, parent: parent, chunk: chunk, edit: $0, source: source, language: language) }
    }

    private func publish() {
        let visible = isPaused ? [] : currentField.map { tracker.visible(in: $0) } ?? []
        let snapshot = IssueSnapshot(field: currentField, issues: visible)
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        publisher.yield(snapshot)
    }
}

/// Each field's last confident language, for the newest fields set; the oldest goes first.
struct FieldLanguages {
    static let capacity = 20

    private var languages: [FieldID: Language] = [:]
    private var order: [FieldID] = []

    subscript(field: FieldID) -> Language? {
        get { languages[field] }
        set {
            order.removeAll { $0 == field }
            languages[field] = newValue
            guard newValue != nil else { return }
            order.append(field)
            if order.count > Self.capacity { languages[order.removeFirst()] = nil }
        }
    }
}
