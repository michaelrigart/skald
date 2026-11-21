import AppKit
import SkaldCore

public final class SpellingChecker: SpellingChecking {
    private final class DocumentTag: @unchecked Sendable { // reason: only read and written on SpellQueue
        var value: Int?

        func allocate() -> Int {
            if let value { return value }
            let tag = NSSpellChecker.uniqueSpellDocumentTag()
            value = tag
            return tag
        }
    }

    private let queue: SpellQueue
    private let documentTag = DocumentTag()

    public convenience init() {
        self.init(queue: .shared)
    }

    init(queue: SpellQueue) {
        self.queue = queue
    }

    deinit {
        let documentTag = documentTag
        queue.enqueue {
            if let tag = documentTag.value { NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
        }
    }

    public func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) async -> [Edit] {
        let documentTag = documentTag
        let text = p.text
        return await queue.run { Self.flags(in: text, language: language, neverTouch: neverTouch, tag: documentTag.allocate()) }
    }

    private static func flags(in text: String, language: Language, neverTouch: Set<String>, tag: Int) -> [Edit] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        let protected = protectedRanges(in: ns, neverTouch)
        var edits: [Edit] = []
        var offset = 0
        while offset < ns.length {
            let found = checker.checkSpelling(
                of: text, startingAt: offset, language: language.rawValue, wrap: false, inSpellDocumentWithTag: tag, wordCount: nil
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            offset = found.location + found.length
            if protected.contains(where: { NSLocationInRange(found.location, $0) && NSMaxRange(found) <= NSMaxRange($0) }) { continue }
            if language == .en, isAcceptedByBritishEnglish(ns.substring(with: found), checker, tag) { continue }
            let guess = language == .en
                ? britishGuess(forWordRange: found, in: text, checker, tag)
                : checker.guesses(forWordRange: found, in: text, language: language.rawValue, inSpellDocumentWithTag: tag)?.first ?? ""
            edits += TextDiff.edits(from: text, to: ns.replacingCharacters(in: found, with: guess))
        }
        return edits
    }

    /// British spelling is the default: the American dictionary ranks its guesses better, so its first guess
    /// stands when the British dictionary accepts it, else the British guess closest to it ("behavior" →
    /// "behaviour", "center" → "centre"), else the American guess. Without an American guess there is none.
    private static func britishGuess(forWordRange range: NSRange, in text: String, _ checker: NSSpellChecker, _ tag: Int) -> String {
        guard let american = checker.guesses(forWordRange: range, in: text, language: "en", inSpellDocumentWithTag: tag)?.first else { return "" }
        if isAcceptedByBritishEnglish(american, checker, tag) { return american }
        let british = checker.guesses(forWordRange: range, in: text, language: "en_GB", inSpellDocumentWithTag: tag) ?? []
        let nearest = british.enumerated()
            .map { (distance: distance($0.element, american), order: $0.offset, guess: $0.element) }
            .filter { $0.distance <= 2 }
            .min { ($0.distance, $0.order) < ($1.distance, $1.order) }
        return nearest?.guess ?? american
    }

    /// Edits between two words, a swap of neighbouring letters counting as one ("center", "centre").
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var d = (0...a.count).map { i in (0...b.count).map { j in i == 0 ? j : j == 0 ? i : 0 } }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    private static func isAcceptedByBritishEnglish(_ word: String, _ checker: NSSpellChecker, _ tag: Int) -> Bool {
        checker.checkSpelling(of: word, startingAt: 0, language: "en_GB", wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
            .location == NSNotFound
    }

    private static func protectedRanges(in text: NSString, _ neverTouch: Set<String>) -> [NSRange] {
        var ranges: [NSRange] = []
        for entry in neverTouch where !entry.isEmpty {
            var from = 0
            while from < text.length {
                let found = text.range(of: entry, options: .caseInsensitive, range: NSRange(location: from, length: text.length - from))
                if found.location == NSNotFound { break }
                ranges.append(found)
                from = found.location + 1
            }
        }
        return ranges
    }
}
