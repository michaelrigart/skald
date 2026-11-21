import Foundation

public enum SchedulerEvent: Sendable {
    case field(FieldEvent), timerFired, snapshot(FieldSnapshot)
    case modelFinished(generation: Int), modelFailed(generation: Int)
    case backgroundSpelled(generation: Int)
    case forget([ParagraphKey]), paused, resumed, recheck
    /// A read in flight was made stale by a change that schedules nothing of its own: read again after the pause.
    case reread
}

public enum SchedulerEffect: Equatable, Sendable {
    case armTimer(deadline: Duration), disarmTimer
    case read(FieldID), suspendIssues(FieldID), revalidate(FieldSnapshot), clearIssues
    case checkSpelling(ParagraphKey, chunk: Paragraph, parent: Paragraph)
    case spellBackground(ParagraphKey, chunk: Paragraph, parent: Paragraph, generation: Int)
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
    /// Every key whose spelling was started, until a snapshot shows it gone. Not capped: a whole field is spelled once.
    private var spellChecked: Set<ParagraphKey> = []
    /// The spell-checked keys that only the background pass has spelled: the caret's visit spells them again.
    private var spelledOnlyInBackground: Set<ParagraphKey> = []
    private var runningBackground: RunningCheck?
    private var backgroundQueue: [Chunk] = []
    private var lastBackgroundGeneration = 0

    public init(pause: Duration = .milliseconds(700), remember: Int = 200) {
        self.pause = pause
        modelChecked = RecentKeys(limit: remember)
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
        case .backgroundSpelled(let generation):
            guard runningBackground?.generation == generation else { return [] }
            return advanceBackground()
        case .forget(let keys):
            modelChecked.remove(keys)
            spellChecked.subtract(keys)
            spelledOnlyInBackground.subtract(keys)
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
        dropBackground()
        spellChecked.removeAll()
        spelledOnlyInBackground.removeAll()
        if field != nil { effects.append(.armTimer(deadline: now + pause)) }
        return effects
    }

    private mutating func resume(at now: Duration) -> [SchedulerEffect] {
        isPaused = false
        return [.armTimer(deadline: now + pause)]
    }

    private mutating func check(_ snapshot: FieldSnapshot) -> [SchedulerEffect] {
        var effects: [SchedulerEffect] = [.revalidate(snapshot)]
        let keyed = ParagraphKeys.keyed(snapshot)
        forgetSpellingGone(from: snapshot, parents: ParagraphKeys.parents(keyed))
        let caret = Paragraphs.around(caret: snapshot.selection.location, in: keyed.map(\.1))
        backgroundQueue = caret.map { queuedChunks(of: keyed, awayFrom: $0, in: snapshot) } ?? []
        guard let caret, let key = keyed.first(where: { $0.1 == caret })?.0 else { return effects + cancelRunning() }
        let chunks = ParagraphKeys.chunkKeys(of: caret, key: key).map {
            Chunk(key: $0.0, chunk: $0.chunk, parent: $0.parent)
        }

        for item in chunks where !spellChecked.contains(item.key) || spelledOnlyInBackground.contains(item.key) {
            spellChecked.insert(item.key)
            spelledOnlyInBackground.remove(item.key)
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
        if runningBackground == nil { effects += advanceBackground() }
        return effects
    }

    /// The spell-checked keys of this snapshot's field that the snapshot shows gone, by the tracker's rule.
    private mutating func forgetSpellingGone(from snapshot: FieldSnapshot, parents: [ParagraphKey: Paragraph]) {
        let gone = spellChecked.filter {
            $0.field == snapshot.field && ParagraphKeys.locate($0, in: parents) == nil && ParagraphKeys.isGone($0, in: snapshot)
        }
        spellChecked.subtract(gone)
        spelledOnlyInBackground.subtract(gone)
    }

    /// Every chunk of the other paragraphs not yet spell-checked, nearest the caret's paragraph first (in UTF-16
    /// units, above before below at equal distance); empty unless the snapshot holds the whole field.
    private func queuedChunks(of keyed: [(ParagraphKey, Paragraph)], awayFrom caret: Paragraph, in snapshot: FieldSnapshot) -> [Chunk] {
        guard snapshot.holdsWholeField else { return [] }
        func distance(_ paragraph: Paragraph) -> (units: Int, below: Bool) {
            paragraph.range.end <= caret.range.location
                ? (caret.range.location - paragraph.range.end, false)
                : (paragraph.range.location - caret.range.end, true)
        }
        return keyed
            .filter { $0.1 != caret }
            .sorted {
                let (a, b) = (distance($0.1), distance($1.1))
                return (a.units, a.below ? 1 : 0) < (b.units, b.below ? 1 : 0)
            }
            .flatMap { ParagraphKeys.chunkKeys(of: $0.1, key: $0.0) }
            .filter { !spellChecked.contains($0.0) }
            .map { Chunk(key: $0.0, chunk: $0.chunk, parent: $0.parent) }
    }

    /// Starts the next queued key not yet spell-checked, or none.
    private mutating func advanceBackground() -> [SchedulerEffect] {
        runningBackground = nil
        while !backgroundQueue.isEmpty {
            let next = backgroundQueue.removeFirst()
            guard !spellChecked.contains(next.key) else { continue }
            spellChecked.insert(next.key)
            spelledOnlyInBackground.insert(next.key)
            lastBackgroundGeneration += 1
            runningBackground = RunningCheck(key: next.key, generation: lastBackgroundGeneration)
            return [.spellBackground(next.key, chunk: next.chunk, parent: next.parent, generation: lastBackgroundGeneration)]
        }
        return []
    }

    private mutating func dropBackground() {
        backgroundQueue = []
        runningBackground = nil
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
        spelledOnlyInBackground.removeAll()
        dropBackground()
    }
}
