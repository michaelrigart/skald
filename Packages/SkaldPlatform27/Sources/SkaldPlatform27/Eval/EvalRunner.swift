import Foundation
import SkaldCore

public enum EvalMode: String, Sendable {
    case model, spelling
}

public struct EvalUsageError: Error, Equatable {
    public let message: String
}

public struct EvalOptions: Equatable, Sendable {
    public var set: String
    public var mode: EvalMode
    public var guardOn: Bool
    public var out: String?

    public static let usage = "usage: skald-eval --set <path> --mode model|spelling [--guard on|off] [--out <path>]"

    public static func parse(_ arguments: [String]) throws(EvalUsageError) -> EvalOptions {
        var set: String?, mode: EvalMode?, guardOn = true, out: String?
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard ["--set", "--mode", "--guard", "--out"].contains(flag) else { throw EvalUsageError(message: "unknown option \(flag)") }
            guard let value = rest.popFirst() else { throw EvalUsageError(message: "\(flag) needs a value") }
            switch flag {
            case "--set":
                set = value
            case "--mode":
                guard let parsed = EvalMode(rawValue: value) else { throw EvalUsageError(message: "--mode is model or spelling") }
                mode = parsed
            case "--guard":
                guard ["on", "off"].contains(value) else { throw EvalUsageError(message: "--guard is on or off") }
                guardOn = value == "on"
            default:
                out = value
            }
        }
        guard let set else { throw EvalUsageError(message: "--set is required") }
        guard let mode else { throw EvalUsageError(message: "--mode is required") }
        return EvalOptions(set: set, mode: mode, guardOn: guardOn, out: out)
    }
}

public enum EvalVerdict: Equatable, Sendable {
    case pass
    case fail([EvalBar.Miss])
    case noVerdict(errors: Int)
}

/// The spec's bar, per language, on the held-out part. A ratio with nothing to count (no proposals, no reference edits) is met.
public enum EvalBar {
    public enum Miss: String, Sendable {
        case precision, cleanParagraphs, recall, latency
    }

    /// A language with a failed request has no verdict, which counts as a miss.
    public static func verdict(_ score: EvalScore, errors: Int, mode: EvalMode) -> EvalVerdict {
        guard errors == 0 else { return .noVerdict(errors: errors) }
        let misses = misses(score, mode: mode)
        return misses.isEmpty ? .pass : .fail(misses)
    }

    public static let minimumPrecision = 0.95
    public static let maximumCleanFlagged = 1
    public static let minimumRecall = 0.90
    public static let maximumP90Ms = 1_000.0

    public static func misses(_ score: EvalScore, mode: EvalMode) -> [Miss] {
        var misses: [Miss] = []
        if score.fp > 0 && score.precision < minimumPrecision { misses.append(.precision) }
        guard mode == .model else { return misses }
        if score.cleanFlagged > maximumCleanFlagged { misses.append(.cleanParagraphs) }
        if score.fn > 0 && score.recall < minimumRecall { misses.append(.recall) }
        if score.p90Ms >= maximumP90Ms { misses.append(.latency) }
        return misses
    }
}

public struct EvalRun: Sendable {
    public var outputs: [EvalOutput] = []
    /// Cases whose detected language was missing or differed from the case's; they ran in the case's language.
    public var languageMisses: [String] = []
    /// Model results the guard discarded whole, by case id.
    public var discarded: [String: DiscardReason] = [:]
}

/// Runs each case through the path the app takes for it, one case at a time, timing the whole path.
public struct EvalRunner: Sendable {
    private struct CaseResult {
        var output: String?
        var error: String?
        var discarded: DiscardReason?
    }

    private let mode: EvalMode
    private let guardOn: Bool
    private let detector: any LanguageDetecting
    private let engine: any Engine
    private let spelling: any SpellingChecking
    private let oracle: any WordOracle
    private let confirmer: any EditConfirming
    private let editGuard = EditGuard(neverTouch: [])

    public init(mode: EvalMode, guardOn: Bool) {
        self.init(
            mode: mode,
            guardOn: guardOn,
            detector: SystemLanguageDetector(),
            engine: AppleEngine(),
            spelling: SpellingChecker(),
            oracle: SystemWordOracle(),
            confirmer: GatedConfirmer(inner: AppleConfirmer(), gate: { _ in true })
        )
    }

    init(
        mode: EvalMode,
        guardOn: Bool,
        detector: any LanguageDetecting,
        engine: any Engine,
        spelling: any SpellingChecking,
        oracle: any WordOracle,
        confirmer: any EditConfirming
    ) {
        self.mode = mode
        self.guardOn = guardOn
        self.detector = detector
        self.engine = engine
        self.spelling = spelling
        self.oracle = oracle
        self.confirmer = confirmer
    }

    public func run(_ cases: [EvalCase]) async -> EvalRun {
        var run = EvalRun()
        let clock = ContinuousClock()
        for item in cases {
            let start = clock.now
            if detector.detect(item.text, previous: nil) != item.lang { run.languageMisses.append(item.id) }
            let result = switch mode {
            case .model: await checkWithModel(item.text, item.lang)
            case .spelling: await checkSpelling(item.text, item.lang)
            }
            let elapsed = start.duration(to: clock.now)
            run.outputs.append(EvalOutput(id: item.id, lang: item.lang, output: result.output, error: result.error, ms: Self.milliseconds(elapsed)))
            if let reason = result.discarded { run.discarded[item.id] = reason }
        }
        return run
    }

    private func checkWithModel(_ text: String, _ language: Language) async -> CaseResult {
        let revised: String
        do {
            revised = try await engine.run(EngineRequest(action: .check, language: language, text: text))
        } catch {
            return CaseResult(error: String(describing: error))
        }
        guard guardOn else { return CaseResult(output: revised) }
        let answer = await ModelAnswer.judge(
            revised, for: text, language: language, editGuard: editGuard, detector: detector, oracle: oracle, confirmer: confirmer
        ) { _ in true }
        switch answer {
        case .discarded(let reason): return CaseResult(output: text, discarded: reason)
        case .kept(let kept): return CaseResult(output: Self.apply(kept, to: text))
        }
    }

    private func checkSpelling(_ text: String, _ language: Language) async -> CaseResult {
        let paragraph = Paragraph(range: TextRange(location: 0, length: text.utf16.count), text: text)
        let flags = await spelling.flags(in: paragraph, language: language, neverTouch: [])
        guard guardOn else { return CaseResult(output: Self.apply(flags, to: text)) }
        let kept = await editGuard.resolve(flags, in: text, language: language, source: .spelling, oracle: oracle, confirmer: nil)
        return CaseResult(output: Self.apply(kept, to: text))
    }

    /// Applies edits through their splices, from the end of the text backwards. Neighbouring spelling flags, each diffed on
    /// its own, share only the whitespace between their words, which both splices keep.
    public static func apply(_ edits: [Edit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.spliceRange.location > $1.spliceRange.location }) {
            result.replaceCharacters(in: NSRange(location: edit.spliceRange.location, length: edit.spliceRange.length), with: edit.spliceText)
        }
        return result as String
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
