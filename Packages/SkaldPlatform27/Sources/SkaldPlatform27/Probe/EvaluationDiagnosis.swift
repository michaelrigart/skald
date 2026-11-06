enum EvaluationTrigger: String, Sendable {
    case keystroke, notification, retry, write
    case quietPeriod = "quiet period"

    /// A notification that pushes back an evaluation a keystroke scheduled does not hide the keystroke.
    static func merged(pending: EvaluationTrigger?, incoming: EvaluationTrigger) -> EvaluationTrigger {
        pending == .keystroke ? .keystroke : incoming
    }
}

struct MarkerFieldState: Sendable, Equatable {
    static let unavailable = MarkerFieldState(initialises: false, textLength: nil, caretLocation: nil, caretLength: nil)

    var initialises: Bool
    var textLength: Int?
    var caretLocation: Int?
    var caretLength: Int?

    var summary: String {
        guard initialises else { return "initialises false" }
        let caret = caretLocation.map { "\($0),\(caretLength ?? 0)" } ?? "none"
        return "initialises true, text length \(textLength.map(String.init) ?? "-"), caret \(caret)"
    }
}

/// Why an evaluation logged no field kind: the evaluation's own result, then a fresh look at each step of a measurement.
struct EvaluationDiagnosis: Sendable, Equatable {
    enum Outcome: String, Sendable {
        case noFocusedElement = "no focused element"
        case resolutionFailed = "resolution failed"
        case valueNil = "value nil"
        case valueRead = "value read"

        static func classify(focusedFound: Bool, resolvedFound: Bool, valueRead: Bool) -> Outcome {
            if !focusedFound { return .noFocusedElement }
            if !resolvedFound { return .resolutionFailed }
            return valueRead ? .valueRead : .valueNil
        }
    }

    var measureReturnedNil: Bool
    var sessionCurrent: Bool
    var outcome: Outcome
    var focusedQueryError: Int32
    var resolvedRole: String?
    var sameAsFocused: Bool?
    var resolvedMarkers: MarkerFieldState
    var focusedMarkers: MarkerFieldState

    var summary: String {
        "measure returned nil \(measureReturnedNil), session current \(sessionCurrent); now \(outcome.rawValue), "
            + "focused query AXError \(focusedQueryError), resolved role \(resolvedRole ?? "-"), "
            + "same as focused \(sameAsFocused.map(String.init) ?? "-"); "
            + "text markers on resolved: \(resolvedMarkers.summary); on focused: \(focusedMarkers.summary)"
    }
}
