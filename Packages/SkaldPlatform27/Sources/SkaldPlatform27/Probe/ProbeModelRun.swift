import Foundation
import FoundationModels
import SkaldCore

enum ProbeModelRun {
    static func outputURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: SkaldCore.bundleID, directoryHint: .isDirectory)
            .appending(path: "probe", directoryHint: .isDirectory)
            .appending(path: "seed-outputs.jsonl", directoryHint: .notDirectory)
    }

    static func run() async {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        PlatformLog.probe.notice("model availability: \(String(describing: model.availability), privacy: .public)")
        guard let seed = Bundle.module.url(forResource: "seed", withExtension: "jsonl"),
              let cases: [EvalCase] = try? EvalScorer.loadJSONL(seed)
        else {
            PlatformLog.probe.notice("model run: seed cases missing")
            return
        }
        guard case .available = model.availability else { return }

        var outputs: [EvalOutput] = []
        for testCase in cases {
            outputs.append(await respond(to: testCase, with: model))
        }
        write(outputs)
        let failed = outputs.filter { $0.output == nil }.count
        PlatformLog.probe.notice("model run: \(outputs.count) cases, \(failed) failed")
    }

    private static func respond(to testCase: EvalCase, with model: SystemLanguageModel) async -> EvalOutput {
        let session = LanguageModelSession(model: model, instructions: Prompts.instructions(.check, testCase.lang))
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let response = try await session.respond(to: testCase.text, options: GenerationOptions(samplingMode: .greedy))
            return EvalOutput(
                id: testCase.id, lang: testCase.lang, output: response.content, error: nil,
                ms: milliseconds(since: started, on: clock)
            )
        } catch {
            return EvalOutput(
                id: testCase.id, lang: testCase.lang, output: nil, error: caseName(of: error),
                ms: milliseconds(since: started, on: clock)
            )
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant, on clock: ContinuousClock) -> Double {
        let elapsed = start.duration(to: clock.now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func caseName(of error: any Error) -> String {
        Mirror(reflecting: error).children.first?.label ?? String(describing: error)
    }

    private static func write(_ outputs: [EvalOutput]) {
        let url = outputURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lines = try outputs.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            PlatformLog.probe.notice("model run: write failed")
        }
    }
}
