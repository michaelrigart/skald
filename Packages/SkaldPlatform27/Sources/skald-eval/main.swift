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

func label(_ verdict: EvalVerdict) -> String {
    switch verdict {
    case .pass: "PASS"
    case .fail(let misses): "FAIL (\(misses.map(\.rawValue).joined(separator: ", ")))"
    case .noVerdict(let errors): "NO VERDICT (\(errors) request \(errors == 1 ? "error" : "errors"))"
    }
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

func write(_ outputs: [EvalOutput], to path: String) {
    do {
        try EvalOutputLines.encode(outputs).write(to: URL(filePath: path), options: .atomic)
    } catch {
        stop("cannot write \(path): \(error)")
    }
}

var session: EvalClaudeSession?
var engine: any Engine = AppleEngine()
var replay: [String: String]?
switch options.mode {
case .claude:
    do throws(EvalUsageError) {
        let opened = try EvalClaudeSession.open(options, environment: ProcessInfo.processInfo.environment, transport: URLSessionTransport())
        session = opened
        engine = opened.engine
    } catch {
        stop(error.message)
    }
case .replay:
    guard let path = options.outputs else { stop(EvalOptions.usage) }
    do {
        replay = try EvalReplay.load(URL(filePath: path))
    } catch {
        stop("cannot read \(path): \(error)")
    }
case .model, .spelling:
    break
}

let runner = EvalRunner(mode: options.mode, guardOn: options.guardOn, engine: engine, replay: replay)
let run: EvalRun
if let session {
    run = await runner.run(cases) { output, raw in
        do throws(EvalUsageError) {
            try await session.files.append(output, raw: raw)
        } catch {
            stop(error.message)
        }
        if let failure = await session.tracker.logFailure { stop(failure) }
    }
    print(await session.tracker.summary)
} else {
    run = await runner.run(cases)
    if let out = options.out {
        write(run.outputs, to: out)
        if !run.raw.isEmpty { write(run.raw, to: out + ".raw.jsonl") }
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
    let missed = run.languageMisses.filter { byID[$0]?.lang == language }.count
    let errors = run.outputs.filter { $0.lang == language && $0.error != nil }.count
    let verdict = EvalBar.verdict(s, errors: errors, mode: options.mode)
    passed = passed && verdict == .pass
    print("""
        \(language.rawValue): precision \(decimal(s.precision)), recall \(decimal(s.recall)), F0.5 \(decimal(s.f05)) \
        (tp \(s.tp), fp \(s.fp), fn \(s.fn)); clean flagged \(s.cleanFlagged)/\(s.cleanTotal); \
        p50 \(Int(s.p50Ms.rounded())) ms, p90 \(Int(s.p90Ms.rounded())) ms; language misses \(missed); errors \(errors): \(label(verdict))
        """)
}
exit(passed ? 0 : 1)
