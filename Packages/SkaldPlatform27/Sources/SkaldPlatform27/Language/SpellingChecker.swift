import AppKit
import SkaldCore

public final class SpellingChecker: SpellingChecking {
    private let queue: SpellQueue
    private let documentTag: Int

    public convenience init() {
        self.init(queue: .shared)
    }

    init(queue: SpellQueue) {
        self.queue = queue
        self.documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    deinit {
        let tag = documentTag
        queue.enqueue { NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
    }

    public func flags(in p: Paragraph, language: Language, neverTouch: Set<String>) async -> [Edit] {
        let tag = documentTag
        let text = p.text
        return await queue.run { Self.flags(in: text, language: language, neverTouch: neverTouch, tag: tag) }
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
            let guess = checker.guesses(forWordRange: found, in: text, language: language.rawValue, inSpellDocumentWithTag: tag)?.first ?? ""
            edits += TextDiff.edits(from: text, to: ns.replacingCharacters(in: found, with: guess))
        }
        return edits
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
