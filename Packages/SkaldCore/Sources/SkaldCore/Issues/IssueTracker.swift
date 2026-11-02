import Foundation

public struct IssueTracker: Sendable {
    private struct Ignored: Hashable, Sendable {
        let key: ParagraphKey
        let edit: Edit
    }

    private var issues: [Issue] = []
    private var suspended: Set<FieldID> = []
    private var ignored: Set<Ignored> = []

    public init() {}

    public mutating func setSpelling(_ issues: [Issue], for key: ParagraphKey) {
        replace(.spelling, with: issues, for: key)
    }

    public mutating func setModel(_ issues: [Issue], for key: ParagraphKey) {
        replace(.model, with: issues, for: key)
        let modelRanges = self.issues.filter { $0.key == key && $0.source == .model }.map(\.fieldRange)
        self.issues.removeAll { issue in
            issue.key == key && issue.source == .spelling
                && !modelRanges.contains { Self.overlap($0, issue.fieldRange) }
        }
    }

    /// Returns the keys whose issues were dropped.
    @discardableResult
    public mutating func revalidate(_ s: FieldSnapshot) -> [ParagraphKey] {
        suspended.remove(s.field)
        let parents = Dictionary(ParagraphKeys.keyed(s).map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        let window = s.offset...(s.offset + s.text.utf16.count)

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
            let old = issue.parent.range
            if s.holdsWholeField || old.end > s.totalLength || (window.contains(old.location) && window.contains(old.end)) {
                if !dropped.contains(issue.key) { dropped.append(issue.key) }
            } else {
                kept.append(issue)
            }
        }
        issues = kept
        return dropped
    }

    public mutating func suspend(_ field: FieldID) {
        suspended.insert(field)
    }

    public mutating func clear() {
        issues.removeAll()
    }

    public mutating func clear(_ key: ParagraphKey) {
        issues.removeAll { $0.key == key }
    }

    public mutating func ignore(_ id: UUID) {
        guard let issue = issue(id) else { return }
        ignored.insert(Ignored(key: issue.key, edit: issue.edit))
        issues.removeAll { $0.id == id }
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

    private mutating func replace(_ source: IssueSource, with new: [Issue], for key: ParagraphKey) {
        issues.removeAll { $0.key == key && $0.source == source }
        issues.append(contentsOf: new.filter { !ignored.contains(Ignored(key: $0.key, edit: $0.edit)) })
    }

    private static func overlap(_ a: TextRange, _ b: TextRange) -> Bool {
        if a.length == 0 || b.length == 0 {
            return a.location <= b.end && b.location <= a.end
        }
        return a.location < b.end && b.location < a.end
    }
}
