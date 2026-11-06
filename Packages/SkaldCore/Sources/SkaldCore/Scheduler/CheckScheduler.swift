import Foundation

public enum SchedulerEvent: Sendable {
    case field(FieldEvent), timerFired, snapshot(FieldSnapshot)
    case modelFinished(generation: Int), modelFailed(generation: Int)
    case forget([ParagraphKey]), paused, resumed, recheck
    /// A read in flight was made stale by a change that schedules nothing of its own: read again after the pause.
    case reread
}

public enum SchedulerEffect: Equatable, Sendable {
    case armTimer(deadline: Duration), disarmTimer
    case read(FieldID), suspendIssues(FieldID), revalidate(FieldSnapshot), clearIssues
    case checkSpelling(ParagraphKey, chunk: Paragraph, parent: Paragraph)
    case checkModel(ParagraphKey, chunk: Paragraph, parent: Paragraph, generation: Int)
    case cancelModel(generation: Int)
}

public struct CheckScheduler: Sendable {
    private struct Chunk: Sendable {
        let key: ParagraphKey
        let chunk: Paragraph
        let parent: Paragraph
    }

    private struct RunningCheck: Sendable {
        let key: ParagraphKey
        let generation: Int
    }

    private struct RecentKeys: Sendable {
        let limit: Int
        private var keys: [ParagraphKey] = []

        init(limit: Int) {
            self.limit = limit
        }

        func contains(_ key: ParagraphKey) -> Bool {
            keys.contains(key)
        }

        mutating func insert(_ key: ParagraphKey) {
            keys.removeAll { $0 == key }
            keys.append(key)
            if keys.count > limit { keys.removeFirst(keys.count - limit) }
        }

        mutating func remove(_ removed: [ParagraphKey]) {
            keys.removeAll { removed.contains($0) }
        }

        mutating func removeAll() {
            keys.removeAll()
        }
    }

    private let pause: Duration
    private var currentField: FieldID?
    private var isPaused = false
    private var running: RunningCheck?
    private var queue: [Chunk] = []
    private var lastGeneration = 0
    private var modelChecked: RecentKeys
    private var spellChecked: RecentKeys

    public init(pause: Duration = .milliseconds(700), remember: Int = 200) {
        self.pause = pause
        modelChecked = RecentKeys(limit: remember)
        spellChecked = RecentKeys(limit: remember)
    }

    public mutating func handle(_ event: SchedulerEvent, at now: Duration) -> [SchedulerEffect] {
        if case .field(.focused(let field)) = event { return focus(field, at: now) }
        if isPaused {
            if case .resumed = event { return resume(at: now) }
            return []
        }
        switch event {
        case .field(.focused):
            return []
        case .field(.edited(let field)):
            guard field == currentField else { return [] }
            return [.suspendIssues(field), .armTimer(deadline: now + pause)]
        case .field(.caretMoved(let field)):
            guard field == currentField else { return [] }
            return [.armTimer(deadline: now + pause)]
        case .timerFired:
            guard let currentField else { return [] }
            return [.read(currentField)]
        case .snapshot(let snapshot):
            guard snapshot.field == currentField else { return [] }
            return check(snapshot)
        case .modelFinished(let generation):
            guard let finished = running, finished.generation == generation else { return [] }
            modelChecked.insert(finished.key)
            return advance()
        case .modelFailed(let generation):
            guard running?.generation == generation else { return [] }
            return advance()
        case .forget(let keys):
            modelChecked.remove(keys)
            spellChecked.remove(keys)
            return []
        case .paused:
            isPaused = true
            var effects: [SchedulerEffect] = [.disarmTimer]
            effects += cancelRunning()
            effects.append(.clearIssues)
            forgetEverything()
            return effects
        case .resumed:
            return resume(at: now)
        case .reread:
            guard currentField != nil else { return [] }
            return [.armTimer(deadline: now + pause)]
        case .recheck:
            var effects = cancelRunning()
            effects.append(.clearIssues)
            forgetEverything()
            effects.append(.armTimer(deadline: now + pause))
            return effects
        }
    }

    private mutating func focus(_ field: FieldID?, at now: Duration) -> [SchedulerEffect] {
        currentField = field
        guard !isPaused else { return [] }
        var effects: [SchedulerEffect] = [.disarmTimer]
        effects += cancelRunning()
        spellChecked.removeAll()
        if field != nil { effects.append(.armTimer(deadline: now + pause)) }
        return effects
    }

    private mutating func resume(at now: Duration) -> [SchedulerEffect] {
        isPaused = false
        return [.armTimer(deadline: now + pause)]
    }

    private mutating func check(_ snapshot: FieldSnapshot) -> [SchedulerEffect] {
        var effects: [SchedulerEffect] = [.revalidate(snapshot)]
        let chunks = ParagraphKeys.chunkKeys(snapshot, caret: snapshot.selection.location).map {
            Chunk(key: $0.0, chunk: $0.chunk, parent: $0.parent)
        }
        guard !chunks.isEmpty else { return effects }

        for item in chunks where !spellChecked.contains(item.key) {
            spellChecked.insert(item.key)
            effects.append(.checkSpelling(item.key, chunk: item.chunk, parent: item.parent))
        }

        let pending = chunks.filter { !modelChecked.contains($0.key) }
        if let running, running.key == pending.first?.key {
            queue = Array(pending.dropFirst())
        } else {
            effects += cancelRunning()
            queue = pending
            effects += advance()
        }
        return effects
    }

    private mutating func advance() -> [SchedulerEffect] {
        running = nil
        guard !queue.isEmpty else { return [] }
        let next = queue.removeFirst()
        lastGeneration += 1
        running = RunningCheck(key: next.key, generation: lastGeneration)
        return [.checkModel(next.key, chunk: next.chunk, parent: next.parent, generation: lastGeneration)]
    }

    private mutating func cancelRunning() -> [SchedulerEffect] {
        queue = []
        guard let cancelled = running else { return [] }
        running = nil
        return [.cancelModel(generation: cancelled.generation)]
    }

    private mutating func forgetEverything() {
        modelChecked.removeAll()
        spellChecked.removeAll()
    }
}
