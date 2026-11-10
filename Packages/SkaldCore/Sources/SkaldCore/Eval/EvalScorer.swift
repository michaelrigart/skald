import Foundation

/// Reproduces the spike's `score.py`: an edit is the token span it replaces plus the replacement tokens.
public enum EvalScorer {
    struct Key: Hashable {
        let span: Range<Int>
        let replacement: [String]
    }

    static func key(of edit: Edit) -> Key {
        Key(span: edit.tokenSpan, replacement: edit.replacementTokens)
    }

    static func keys(_ original: String, _ revised: String) -> Set<Key> {
        Set(TextDiff.edits(from: original, to: revised).map(key(of:)))
    }

    public static func score(_ cases: [EvalCase], _ outputs: [EvalOutput]) -> EvalScore {
        let byID = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var s = EvalScore()
        for row in outputs {
            guard let item = byID[row.id] else { continue }
            let reference = keys(item.text, item.ref)
            let hypothesis: Set<Key>
            if let output = row.output {
                hypothesis = keys(item.text, output.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                hypothesis = []
            }
            s.tp += reference.intersection(hypothesis).count
            s.fp += hypothesis.subtracting(reference).count
            s.fn += reference.subtracting(hypothesis).count
            if reference.isEmpty {
                s.cleanTotal += 1
                if !hypothesis.isEmpty { s.cleanFlagged += 1 }
            }
        }
        let tp = Double(s.tp), fp = Double(s.fp), fn = Double(s.fn)
        s.precision = s.tp + s.fp > 0 ? tp / (tp + fp) : 0
        s.recall = s.tp + s.fn > 0 ? tp / (tp + fn) : 0
        let sum = 0.25 * s.precision + s.recall
        s.f05 = s.precision + s.recall > 0 ? 1.25 * s.precision * s.recall / sum : 0
        let ms = outputs.map(\.ms).sorted()
        if !ms.isEmpty {
            let mid = ms.count / 2
            s.p50Ms = ms.count.isMultiple(of: 2) ? (ms[mid - 1] + ms[mid]) / 2 : ms[mid]
            s.p90Ms = ms[max(Int(Double(ms.count) * 0.9) - 1, 0)]
        }
        return s
    }

    public static func byLanguage(_ cases: [EvalCase], _ outputs: [EvalOutput]) -> [Language: EvalScore] {
        var result: [Language: EvalScore] = [:]
        for lang in Language.allCases {
            let langCases = cases.filter { $0.lang == lang }
            guard !langCases.isEmpty else { continue }
            let ids = Set(langCases.map(\.id))
            result[lang] = score(langCases, outputs.filter { ids.contains($0.id) })
        }
        return result
    }

    public static func loadJSONL<T: Decodable>(_ url: URL) throws -> [T] {
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { try decoder.decode(T.self, from: Data($0.utf8)) }
    }
}
