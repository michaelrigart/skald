import NaturalLanguage
import SkaldCore

public struct SystemLanguageDetector: LanguageDetecting {
    private static let minimumUnits = 20
    private static let minimumConfidence = 0.6
    private static let candidates: [(NLLanguage, Language)] = [(.english, .en), (.dutch, .nl), (.french, .fr)]

    public init() {}

    public func detect(_ text: String, previous: Language?) -> Language? {
        guard text.utf16.count >= Self.minimumUnits else { return previous }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Self.candidates.map(\.0)
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let best = Self.candidates
            .compactMap { candidate in hypotheses[candidate.0].map { (candidate.1, $0) } }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= Self.minimumConfidence else { return previous }
        return best.0
    }
}
