import Foundation

/// Remembers a detector's answers per text and previous language, so a pass over many paragraphs asks about each
/// text once however many neighbours' searches reach it. `prune` bounds it to the texts still in the field.
final class DetectionMemo: LanguageDetecting, @unchecked Sendable { // reason: the answers are only touched under the lock
    private struct Query: Hashable {
        let text: String
        let previous: Language?
    }

    private let detector: any LanguageDetecting
    private let lock = NSLock()
    private var answers: [Query: Language?] = [:]

    init(_ detector: any LanguageDetecting) {
        self.detector = detector
    }

    func detect(_ text: String, previous: Language?) -> Language? {
        let query = Query(text: text, previous: previous)
        if let known = lock.withLock({ answers[query] }) { return known }
        let answer = detector.detect(text, previous: previous)
        lock.withLock { answers[query] = .some(answer) }
        return answer
    }

    func prune(keeping texts: Set<String>) {
        lock.withLock { answers = answers.filter { texts.contains($0.key.text) } }
    }
}
