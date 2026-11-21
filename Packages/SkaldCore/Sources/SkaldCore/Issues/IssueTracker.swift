import Foundation

public struct IssueTracker: Sendable {
    private struct Ignored: Hashable, Sendable {
        let key: ParagraphKey
        let edit: Edit
    }

    private var issues: [Issue] = []
    private var suspended: Set<FieldID> = []
    private var ignored: Set<Ignored> = []
    private var modelResults: [ParagraphKey: [TextRange]] = [:]
    /// The paragraphs of the field last revalidated that a spelling or model result was stored for, until they are
    /// cleared or gone. Revalidating another field drops the rest; focusing a field checks it again.
    private var resultKeys: Set<ParagraphKey> = []

    public init() {}

    public mutating func setSpelling(_ issues: [Issue], for key: ParagraphKey) {
        resultKeys.insert(key)
        self.issues.removeAll { $0.key == key && $0.source == .spelling }
        let modelRanges = modelResults[key]
        self.issues.append(contentsOf: issues.filter { issue in
            !ignored.contains(Ignored(key: issue.key, edit: issue.edit))
                && (modelRanges.map { Self.survives(issue, modelRanges: $0) } ?? true)
        })
    }

    public mutating func setModel(_ issues: [Issue], for key: ParagraphKey) {
        resultKeys.insert(key)
        let kept = issues.filter { !ignored.contains(Ignored(key: $0.key, edit: $0.edit)) }
        let modelRanges = issues.map(\.edit.range)
        modelResults[key] = modelRanges
        self.issues.removeAll { issue in
            issue.key == key && (issue.source == .model || !Self.survives(issue, modelRanges: modelRanges))
        }
        self.issues.append(contentsOf: kept)
    }

    /// Returns the keys whose issues or model result were dropped.
    @discardableResult
    public mutating func revalidate(_ s: FieldSnapshot) -> [ParagraphKey] {
        suspended.remove(s.field)
        let parents = ParagraphKeys.parents(in: s)

        var kept: [Issue] = []
        var dropped: [ParagraphKey] = []
        for issue in issues {
            guard issue.key.field == s.field else {
                kept.append(issue)
                continue
            }
            if let (parent, chunk) = ParagraphKeys.locate(issue.key, in: parents) {
                kept.append(Issue(
                    id: issue.id,
                    key: issue.key,
                    parent: parent,
                    chunk: chunk,
                    edit: issue.edit,
                    source: issue.source,
                    language: issue.language,
                    engine: issue.engine,
                    kind: issue.kind,
                    alternatives: issue.alternatives
                ))
                continue
            }
            if ParagraphKeys.isGone(issue.key, in: s) {
                if !dropped.contains(issue.key) { dropped.append(issue.key) }
            } else {
                kept.append(issue)
            }
        }
        issues = kept

        for key in modelResults.keys where key.field == s.field {
            if ParagraphKeys.locate(key, in: parents) != nil { continue }
            guard ParagraphKeys.isGone(key, in: s) else { continue }
            modelResults[key] = nil
            if !dropped.contains(key) { dropped.append(key) }
        }
        resultKeys = resultKeys.filter { key in
            key.field == s.field && (ParagraphKeys.locate(key, in: parents) != nil || !ParagraphKeys.isGone(key, in: s))
        }
        return dropped
    }

    /// Drops the alternatives `keep` refuses, from every issue that has one.
    public mutating func keepAlternatives(where keep: (Edit, Issue) -> Bool) {
        issues = issues.map { issue in
            let kept = issue.keepingAlternatives { keep($0, issue) }
            return kept.alternatives.count == issue.alternatives.count ? issue : kept
        }
    }

    public mutating func suspend(_ field: FieldID) {
        suspended.insert(field)
    }

    public mutating func clear() {
        issues.removeAll()
        modelResults.removeAll()
        resultKeys.removeAll()
    }

    public mutating func clear(_ key: ParagraphKey) {
        issues.removeAll { $0.key == key }
        modelResults[key] = nil
        resultKeys.remove(key)
    }

    public mutating func ignore(_ id: UUID) {
        guard let issue = issue(id) else { return }
        ignored.insert(Ignored(key: issue.key, edit: issue.edit))
        remove(id)
    }

    /// Drops the issue and its twin, the same fix on the same word from the other source.
    public mutating func remove(_ id: UUID) {
        guard let issue = issue(id) else { return }
        let entry = Ignored(key: issue.key, edit: issue.edit)
        issues.removeAll { Ignored(key: $0.key, edit: $0.edit) == entry }
    }

    /// Returns the keys whose issues were dropped.
    @discardableResult
    public mutating func removeAll(word: String) -> [ParagraphKey] {
        removeAll { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    /// Returns the keys whose issues were dropped.
    @discardableResult
    public mutating func removeAll(where shouldDrop: (Issue) -> Bool) -> [ParagraphKey] {
        var dropped: [ParagraphKey] = []
        issues.removeAll { issue in
            guard shouldDrop(issue) else { return false }
            if !dropped.contains(issue.key) { dropped.append(issue.key) }
            return true
        }
        return dropped
    }

    public func visible(in field: FieldID) -> [Issue] {
        guard !suspended.contains(field) else { return [] }
        return issues
            .filter { $0.key.field == field }
            .sorted { $0.fieldRange.location < $1.fieldRange.location }
    }

    /// Whether a spelling or model result has been stored for a paragraph of the field and is still held; false while
    /// the field is suspended.
    public func hasResults(in field: FieldID) -> Bool {
        !suspended.contains(field) && resultKeys.contains { $0.field == field }
    }

    /// Whether every one of the keys has a stored result; false while the field is suspended.
    public func hasResults(for keys: [ParagraphKey], in field: FieldID) -> Bool {
        !suspended.contains(field) && keys.allSatisfy { resultKeys.contains($0) }
    }

    public func hasModelIssues(for key: ParagraphKey, from engine: EngineKind) -> Bool {
        issues.contains { $0.key == key && $0.source == .model && $0.engine == engine }
    }

    public func issue(_ id: UUID) -> Issue? {
        issues.first { $0.id == id }
    }

    private static func survives(_ spelling: Issue, modelRanges: [TextRange]) -> Bool {
        modelRanges.contains { overlap($0, spelling.edit.range) }
    }

    /// A zero-length edit sits on a token boundary and overlaps only when strictly inside the other range.
    private static func overlap(_ a: TextRange, _ b: TextRange) -> Bool {
        if a.length == 0 { return b.location < a.location && a.location < b.end }
        if b.length == 0 { return a.location < b.location && b.location < a.end }
        return a.location < b.end && b.location < a.end
    }
}
