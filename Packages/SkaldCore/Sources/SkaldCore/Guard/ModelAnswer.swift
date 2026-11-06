/// A model's answer for one chunk, judged the one way checking while typing, the panel's Fix and the evaluation
/// share: cleaned, discarded whole when its language changed or it changed too much, then diffed and resolved
/// edit by edit, asking the confirmer only while `mayConfirm` allows it, without edits touching a never-touch word.
public enum ModelAnswer: Equatable, Sendable {
    case kept([Edit])
    case discarded(DiscardReason)

    public static func judge(
        _ output: String,
        for chunk: String,
        language: Language,
        editGuard: EditGuard,
        detector: any LanguageDetecting,
        oracle: any WordOracle,
        confirmer: (any EditConfirming)?,
        mayConfirm: @escaping @Sendable (Language) async -> Bool
    ) async -> ModelAnswer {
        let revised = OutputCleaner.clean(output, input: chunk)
        let whole = editGuard.judgeWhole(
            original: chunk, revised: revised, language: language, revisedLanguage: detector.detect(revised, previous: nil)
        )
        if case .discarded(let reason) = whole { return .discarded(reason) }
        let gated = confirmer.map { GatedConfirmer(inner: $0, gate: mayConfirm) }
        let edits = TextDiff.edits(from: chunk, to: revised)
        let kept = await editGuard.resolve(edits, in: chunk, language: language, source: .model, oracle: oracle, confirmer: gated)
        return .kept(kept.filter { !editGuard.touchesNeverTouch($0, in: chunk) })
    }
}
