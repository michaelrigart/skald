public struct EvalCase: Codable, Sendable {
    public let id: String
    public let lang: Language
    public let text: String
    public let ref: String

    public init(id: String, lang: Language, text: String, ref: String) {
        self.id = id
        self.lang = lang
        self.text = text
        self.ref = ref
    }
}

public struct EvalOutput: Codable, Sendable {
    public let id: String
    public let lang: Language
    public let output: String?
    public let error: String?
    public let ms: Double

    public init(id: String, lang: Language, output: String?, error: String?, ms: Double) {
        self.id = id
        self.lang = lang
        self.output = output
        self.error = error
        self.ms = ms
    }
}

public struct EvalScore: Equatable, Sendable {
    public var tp = 0, fp = 0, fn = 0
    public var cleanFlagged = 0, cleanTotal = 0
    public var precision = 0.0, recall = 0.0, f05 = 0.0
    public var p50Ms = 0.0, p90Ms = 0.0
}
