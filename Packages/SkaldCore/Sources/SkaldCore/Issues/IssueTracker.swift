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

    public init() {}

    public mutating func setSpelling(_ issues: [Issue], for key: ParagraphKey) {
        self.issues.removeAll { $0.key == key && $0.source == .spelling }
        let modelRanges = modelResults[key]
        self.issues.append(contentsOf: issues.filter { issue in
            !ignored.contains(Ignored(key: issue.key, edit: issue.edit))
                && (modelRanges.map { Self.survives(issue, modelRanges: $0) } ?? true)
        })
    }

    public mutating func setModel(_ issues: [Issue], for key: ParagraphKey) {
        let kept = issues.filter { !ignored.contains(Ignored(key: $0.key, edit: $0.edit)) }
        let modelRanges = issues.map(\.edit.range)
        modelResults[key] = modelRanges
        self.issues.removeAll { issue in
            issue.key == key && (issue.source == .model || !Self.survives(issue, modelRanges: modelRanges))
        }
        self.issues.append(contentsOf: kept)
    }

    /// Returns the keys whose issues were dropped.
    @discardableResult
    public mutating func revalidate(_ s: FieldSnapshot) -> [ParagraphKey] {
        suspended.remove(s.field)
        let parents = Dictionary(ParagraphKeys.keyed(s).map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        let window = s.offset...(s.offset + s.text.utf16.count)

        func isGone(_ old: TextRange) -> Bool {
            s.holdsWholeField || old.end > s.totalLength || (window.contains(old.location) && window.contains(old.end))
        }

        var kept: [Issue] = []
        var dropped: [ParagraphKey] = []
        for issue in issues {
            guard issue.key.field == s.field else {
                kept.append(issue)
                continue
            }
            if let parent = parents[issue.key.withChunk(0)] {
                let chunks = Paragraphs.chunks(parent)
                if issue.key.chunk < chunks.count {
                    kept.append(Issue(
                        id: issue.id,
                        key: issue.key,
                        parent: parent,
                        chunk: chunks[issue.key.chunk],
                        edit: issue.edit,
                        source: issue.source,
                        language: issue.language
                    ))
                    continue
                }
            }
            if isGone(issue.parent.range) {
                if !dropped.contains(issue.key) { dropped.append(issue.key) }
            } else {
                kept.append(issue)
            }
        }
        issues = kept

        for key in modelResults.keys where key.field == s.field {
            if let parent = parents[key.withChunk(0)], key.chunk < Paragraphs.chunks(parent).count { continue }
            switch key.position {
            case .occurrence: modelResults[key] = nil
            case .location(let location):
                if isGone(TextRange(location: location, length: key.text.utf16.count)) { modelResults[key] = nil }
            }
        }
        return dropped
    }

    public mutating func suspend(_ field: FieldID) {
        suspended.insert(field)
    }

    public mutating func clear() {
        issues.removeAll()
        modelResults.removeAll()
    }

    public mutating func clear(_ key: ParagraphKey) {
        issues.removeAll { $0.key == key }
        modelResults[key] = nil
    }

    public mutating func ignore(_ id: UUID) {
        guard let issue = issue(id) else { return }
        let entry = Ignored(key: issue.key, edit: issue.edit)
        ignored.insert(entry)
        issues.removeAll { Ignored(key: $0.key, edit: $0.edit) == entry }
    }

    public mutating func removeAll(word: String) {
        issues.removeAll { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    public func visible(in field: FieldID) -> [Issue] {
        guard !suspended.contains(field) else { return [] }
        return issues
            .filter { $0.key.field == field }
            .sorted { $0.fieldRange.location < $1.fieldRange.location }
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
