import Foundation

public struct Edit: Hashable, Sendable {
    /// Token indices in the original text that this edit replaces (empty for an insertion).
    public let tokenSpan: Range<Int>
    public let replacementTokens: [String]
    /// The changed original tokens (zero length at the next token's start for an insertion).
    public let range: TextRange
    public let original: String
    public let replacement: String
    /// The original text between the neighbouring unchanged tokens.
    public let spliceRange: TextRange
    /// The revised text between the same two unchanged tokens.
    public let spliceText: String
}

public enum TextDiff {
    public static func edits(from original: String, to revised: String) -> [Edit] {
        let a = Tokenizer.tokens(in: original)
        let b = Tokenizer.tokens(in: revised)
        let originalUnits = Array(original.utf16)
        let revisedUnits = Array(revised.utf16)

        func slice(_ units: [UInt16], _ lo: Int, _ hi: Int) -> String {
            String(decoding: units[lo..<hi], as: UTF16.self)
        }
        func trimmed(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var edits: [Edit] = []
        for op in SequenceMatcher(a.map(\.text), b.map(\.text)).opcodes() where op.tag != .equal {
            let range: TextRange
            let originalText: String
            if op.i1 < op.i2 {
                range = TextRange(location: a[op.i1].range.location, length: a[op.i2 - 1].range.end - a[op.i1].range.location)
                originalText = trimmed(slice(originalUnits, range.location, range.end))
            } else {
                let at = op.i1 < a.count ? a[op.i1].range.location : (a.last?.range.end ?? 0)
                range = TextRange(location: at, length: 0)
                originalText = ""
            }
            let replacementText: String
            if op.j1 < op.j2 {
                replacementText = trimmed(slice(revisedUnits, b[op.j1].range.location, b[op.j2 - 1].range.end))
            } else {
                replacementText = ""
            }

            let spliceStart = op.i1 > 0 ? a[op.i1 - 1].range.end : 0
            let spliceEnd = op.i2 < a.count ? a[op.i2].range.location : originalUnits.count
            let revisedStart = op.j1 > 0 ? b[op.j1 - 1].range.end : 0
            let revisedEnd = op.j2 < b.count ? b[op.j2].range.location : revisedUnits.count

            edits.append(Edit(
                tokenSpan: op.i1..<op.i2,
                replacementTokens: b[op.j1..<op.j2].map(\.text),
                range: range,
                original: originalText,
                replacement: replacementText,
                spliceRange: TextRange(location: spliceStart, length: spliceEnd - spliceStart),
                spliceText: slice(revisedUnits, revisedStart, revisedEnd)
            ))
        }
        return edits
    }
}

/// A port of Python's `difflib.SequenceMatcher` with `autojunk=False` and no junk function.
struct SequenceMatcher {
    enum Tag { case equal, replace, delete, insert }
    struct Opcode { let tag: Tag; let i1, i2, j1, j2: Int }
    private struct Block { let i, j, size: Int }

    private let a: [String]
    private let b: [String]
    private var b2j: [String: [Int]] = [:]

    init(_ a: [String], _ b: [String]) {
        self.a = a
        self.b = b
        for (j, element) in b.enumerated() { b2j[element, default: []].append(j) }
    }

    private func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> Block {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize {
                    besti = i - k + 1
                    bestj = j - k + 1
                    bestsize = k
                }
            }
            j2len = newj2len
        }
        return Block(i: besti, j: bestj, size: bestsize)
    }

    private func matchingBlocks() -> [Block] {
        var queue = [(0, a.count, 0, b.count)]
        var found: [Block] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let m = longestMatch(alo, ahi, blo, bhi)
            guard m.size > 0 else { continue }
            found.append(m)
            if alo < m.i && blo < m.j { queue.append((alo, m.i, blo, m.j)) }
            if m.i + m.size < ahi && m.j + m.size < bhi { queue.append((m.i + m.size, ahi, m.j + m.size, bhi)) }
        }
        found.sort { ($0.i, $0.j, $0.size) < ($1.i, $1.j, $1.size) }
        var merged: [Block] = []
        for block in found {
            if let last = merged.last, last.i + last.size == block.i, last.j + last.size == block.j {
                merged[merged.count - 1] = Block(i: last.i, j: last.j, size: last.size + block.size)
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    func opcodes() -> [Opcode] {
        var ops: [Opcode] = []
        var i = 0, j = 0
        for block in matchingBlocks() + [Block(i: a.count, j: b.count, size: 0)] {
            if i < block.i && j < block.j {
                ops.append(Opcode(tag: .replace, i1: i, i2: block.i, j1: j, j2: block.j))
            } else if i < block.i {
                ops.append(Opcode(tag: .delete, i1: i, i2: block.i, j1: j, j2: block.j))
            } else if j < block.j {
                ops.append(Opcode(tag: .insert, i1: i, i2: block.i, j1: j, j2: block.j))
            }
            i = block.i + block.size
            j = block.j + block.size
            if block.size > 0 {
                ops.append(Opcode(tag: .equal, i1: block.i, i2: i, j1: block.j, j2: j))
            }
        }
        return ops
    }
}
