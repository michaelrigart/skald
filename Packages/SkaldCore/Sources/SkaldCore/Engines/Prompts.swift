public enum Prompts {
    private static let proofreader = """
        You are a proofreader. Fix only spelling, grammar and punctuation errors in the user's text. \
        Keep the original language, wording, tone, technical terms, names and informal style. \
        Belgian Dutch and Belgian French usage is correct and must stay. \
        Do not rephrase or improve style. \
        Reply with the corrected text only, with no explanation. \
        If there are no errors, reply with the text exactly as given.
        """

    public static func instructions(_ action: EngineAction, _ language: Language) -> String {
        let name = languageName(language)
        switch action {
        case .check, .fix:
            return "\(proofreader) The text is written in \(name). Reply in \(name). Leave any English words in it unchanged."
        case .clearer:
            return rewrite("so it is clearer and easier to read", name)
        case .shorter:
            return rewrite("so it is shorter and to the point", name)
        case .moreFormal:
            return rewrite("so it is more formal and polite", name)
        case .friendlier:
            return rewrite("so it is friendlier and warmer", name)
        case .confirm:
            return """
                You check one proposed change in a \(name) text. \
                Answer yes if the original words are an error and the change corrects it. \
                Answer no if the original words were already correct and the change only rewords, translates or changes tense or style. \
                Reply with yes or no only.
                """
        }
    }

    public static func prompt(_ request: EngineRequest) -> String {
        guard request.action == .confirm else { return request.text }
        return "Text: \(request.text)\nOriginal: \(request.confirmOriginal ?? "")\nChange to: \(request.confirmReplacement ?? "")"
    }

    private static func rewrite(_ goal: String, _ name: String) -> String {
        """
        You are an editor. Rewrite the user's text \(goal). \
        Keep its meaning, its facts, its names and its language. \
        Reply with the rewritten text only. The text is written in \(name). Reply in \(name).
        """
    }

    private static func languageName(_ language: Language) -> String {
        switch language {
        case .en: "English"
        case .nl: "Dutch"
        case .fr: "French"
        }
    }
}
