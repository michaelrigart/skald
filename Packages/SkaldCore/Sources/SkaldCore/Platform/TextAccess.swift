public enum FieldEvent: Equatable, Sendable {
    case focused(FieldID?), edited(FieldID), caretMoved(FieldID)
}

public struct ExpectedText: Equatable, Sendable {
    public let range: TextRange
    public let text: String

    public init(range: TextRange, text: String) {
        self.range = range
        self.text = text
    }
}

public struct SelectionCapture: Equatable, Sendable {
    public let field: FieldID
    public let selection: TextRange
    public let selectedText: String
    /// The paragraphs overlapping the selection, or the caret's paragraph when the selection is empty.
    public let context: ExpectedText

    public init(field: FieldID, selection: TextRange, selectedText: String, context: ExpectedText) {
        self.field = field
        self.selection = selection
        self.selectedText = selectedText
        self.context = context
    }
}

public struct AccessCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let read = AccessCapabilities(rawValue: 1 << 0)
    public static let rangeBounds = AccessCapabilities(rawValue: 1 << 1)
    public static let fieldFrame = AccessCapabilities(rawValue: 1 << 2)
    public static let cleanWrite = AccessCapabilities(rawValue: 1 << 3)
}

public enum ReplaceOutcome: Equatable, Sendable {
    case replaced, refusedChanged, refusedOtherField, unsupported, failed
}

public protocol TextAccess: Sendable {
    var events: AsyncStream<FieldEvent> { get }
    func snapshot(of field: FieldID) async -> FieldSnapshot?
    func capabilities(for app: String) async -> AccessCapabilities
    func capture(of field: FieldID) async -> SelectionCapture?
    func replace(_ range: TextRange, expected: ExpectedText, with text: String, in field: FieldID) async -> ReplaceOutcome
}
