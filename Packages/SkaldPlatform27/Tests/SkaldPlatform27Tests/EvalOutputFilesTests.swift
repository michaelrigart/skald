import Foundation
import SkaldCore
import Testing
@testable import SkaldPlatform27

private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "skald-eval-\(UUID().uuidString)-\(name)")
}

private func options(_ mode: EvalMode, out: String) -> EvalOptions {
    EvalOptions(set: "s.jsonl", mode: mode, guardOn: true, out: out, outputs: mode == .replay ? "r.jsonl" : nil)
}

private let answer = EvalOutput(id: "a", lang: .nl, output: "x", error: nil, ms: 1)

struct EvalOutputFilesTests {
    @Test("a run never overwrites an earlier run's output or raw answers, and refuses before it runs", arguments: [
        (EvalMode.model, ""), (.model, ".raw.jsonl"), (.replay, ""), (.replay, ".raw.jsonl"), (.spelling, ""),
    ] as [(EvalMode, String)])
    func anEarlierRunIsKept(_ example: (EvalMode, String)) throws {
        let out = temporaryFile("out.jsonl")
        let existing = URL(filePath: out.path + example.1)
        try "paid answer\n".write(to: existing, atomically: true, encoding: .utf8)
        defer { for path in [out.path, EvalOutputFiles.rawPath(out.path)] { try? FileManager.default.removeItem(atPath: path) } }
        #expect(throws: EvalUsageError(message: "\(existing.path) already exists; skald-eval never overwrites an earlier run's output")) {
            try EvalOutputFiles.requireFresh(options(example.0, out: out.path))
        }
        var run = EvalRun()
        run.outputs = [answer]
        run.raw = example.0.isModelPath ? [answer] : []
        #expect(throws: EvalUsageError.self) { try EvalOutputFiles.save(run, to: out.path) }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "paid answer\n")
    }

    @Test func aFreshOutputIsWrittenWithItsRawAnswers() throws {
        let out = temporaryFile("out.jsonl")
        defer { for path in [out.path, EvalOutputFiles.rawPath(out.path)] { try? FileManager.default.removeItem(atPath: path) } }
        try EvalOutputFiles.requireFresh(options(.model, out: out.path))
        var run = EvalRun()
        run.outputs = [answer]
        run.raw = [answer]
        try EvalOutputFiles.save(run, to: out.path)
        #expect(try String(contentsOf: out, encoding: .utf8).split(separator: "\n").count == 1)
        #expect(try String(contentsOfFile: EvalOutputFiles.rawPath(out.path), encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test func aClaudeRunLeavesItsFilesToTheClaudeSession() throws {
        let out = temporaryFile("out.jsonl")
        try "paid answer\n".write(to: out, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: out) }
        try EvalOutputFiles.requireFresh(options(.claude, out: out.path))
    }
}
