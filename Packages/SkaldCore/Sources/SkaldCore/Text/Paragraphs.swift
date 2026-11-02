import Foundation

public struct Paragraph: Hashable, Sendable {
    public let range: TextRange
    public let text: String

    public init(range: TextRange, text: String) {
        self.range = range
        self.text = text
    }
}

public enum Paragraphs {
    public static func all(in text: String, offset: Int) -> [Paragraph] {
        let units = Array(text.utf16)
        var result: [Paragraph] = []
        var start = 0
        var i = 0

        func close(at end: Int) {
            guard end > start else { return }
            result.append(Paragraph(
                range: TextRange(location: offset + start, length: end - start),
                text: String(decoding: units[start..<end], as: UTF16.self)
            ))
        }

        while i < units.count {
            switch units[i] {
            case 0x0A, 0x2028, 0x2029:
                close(at: i)
                i += 1
                start = i
            case 0x0D:
                close(at: i)
                i += (i + 1 < units.count && units[i + 1] == 0x0A) ? 2 : 1
                start = i
            default:
                i += 1
            }
        }
        close(at: units.count)
        return result
    }

    public static func around(caret: Int, in text: String, offset: Int) -> Paragraph? {
        all(in: text, offset: offset).first { $0.range.location <= caret && caret <= $0.range.end }
    }

    public static func chunks(_ p: Paragraph, limit: Int = 1200) -> [Paragraph] {
        let units = Array(p.text.utf16)
        guard units.count > limit else { return [p] }

        var sentences: [Range<Int>] = []
        var start = 0
        var i = 0
        while i < units.count {
            let unit = units[i]
            i += 1
            guard unit == 0x2E || unit == 0x21 || unit == 0x3F, i < units.count, isWhitespace(units[i]) else { continue }
            while i < units.count, isWhitespace(units[i]) { i += 1 }
            sentences.append(start..<i)
            start = i
        }
        if start < units.count { sentences.append(start..<units.count) }

        var spans: [Range<Int>] = []
        var current: Range<Int>?
        for sentence in sentences {
            if let open = current, sentence.upperBound - open.lowerBound <= limit {
                current = open.lowerBound..<sentence.upperBound
            } else {
                if let open = current { spans.append(open) }
                current = sentence
            }
        }
        if let open = current { spans.append(open) }

        return spans.map {
            Paragraph(
                range: TextRange(location: p.range.location + $0.lowerBound, length: $0.count),
                text: String(decoding: units[$0], as: UTF16.self)
            )
        }
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
