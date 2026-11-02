import Foundation
import SkaldCore
import SkaldPlatform27

func stop(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

func decimal(_ value: Double) -> String {
    String(format: "%.2f", value)
}

let options: EvalOptions
do throws(EvalUsageError) {
    options = try EvalOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    stop("\(error.message)\n\(EvalOptions.usage)")
}

let cases: [EvalCase]
do {
    cases = try EvalScorer.loadJSONL(URL(filePath: options.set))
} catch {
    stop("cannot read \(options.set): \(error)")
}

let run = await EvalRunner(mode: options.mode, guardOn: options.guardOn).run(cases)

if let out = options.out {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        let lines = try run.outputs.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined()
        try lines.write(to: URL(filePath: out), atomically: true, encoding: .utf8)
    } catch {
        stop("cannot write \(out): \(error)")
    }
}

let byID = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
let languageMisses = Set(run.languageMisses)

print("\(options.set): mode \(options.mode.rawValue), guard \(options.guardOn ? "on" : "off"), \(cases.count) cases")
for output in run.outputs {
    guard let item = byID[output.id] else { continue }
    let s = EvalScorer.score([item], [output])
    var notes: [String] = []
    if s.fp > 0 || s.fn > 0 { notes.append("fp \(s.fp) fn \(s.fn)") }
    if let reason = run.discarded[item.id] { notes.append("discarded (\(reason))") }
    if languageMisses.contains(item.id) { notes.append("language miss") }
    if let error = output.error { notes.append("error \(error)") }
    guard !notes.isEmpty else { continue }
    print("  \(item.id): \(notes.joined(separator: ", "))")
    if s.fp > 0 || s.fn > 0 {
        print("    text: \(item.text)\n    ref:  \(item.ref)\n    out:  \(output.output ?? "—")")
    }
}

var passed = true
for (language, s) in EvalScorer.byLanguage(cases, run.outputs).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
    let misses = EvalBar.misses(s, mode: options.mode)
    passed = passed && misses.isEmpty
    let missed = run.languageMisses.filter { byID[$0]?.lang == language }.count
    let errors = run.outputs.filter { $0.lang == language && $0.error != nil }.count
    let verdict = misses.isEmpty ? "PASS" : "FAIL (\(misses.map(\.rawValue).joined(separator: ", ")))"
    print("""
        \(language.rawValue): precision \(decimal(s.precision)), recall \(decimal(s.recall)), F0.5 \(decimal(s.f05)) \
        (tp \(s.tp), fp \(s.fp), fn \(s.fn)); clean flagged \(s.cleanFlagged)/\(s.cleanTotal); \
        p50 \(Int(s.p50Ms.rounded())) ms, p90 \(Int(s.p90Ms.rounded())) ms; language misses \(missed); errors \(errors): \(verdict)
        """)
}
exit(passed ? 0 : 1)
