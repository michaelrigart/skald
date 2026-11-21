import Testing
@testable import SkaldCore

@Test func checkInstructionsInDutchArePinnedVerbatim() {
    #expect(Prompts.instructions(.check, .nl) == """
        You are a proofreader. Fix only spelling, grammar and punctuation errors in the user's text. \
        Keep the original language, wording, tone, technical terms, names and informal style. \
        Belgian Dutch and Belgian French usage is correct and must stay. \
        Do not rephrase or improve style. \
        Reply with the corrected text only, with no explanation. \
        If there are no errors, reply with the text exactly as given. \
        The text is written in Dutch. Reply in Dutch. Leave any English words in it unchanged.
        """)
}

@Test func fixUsesTheCheckInstructionsInEveryLanguage() {
    for language in Language.allCases {
        #expect(Prompts.instructions(.fix, language) == Prompts.instructions(.check, language))
    }
    #expect(Prompts.instructions(.check, .en).hasSuffix("The text is written in English. Reply in English. Leave any English words in it unchanged."))
    #expect(Prompts.instructions(.fix, .fr).hasSuffix("The text is written in French. Reply in French. Leave any English words in it unchanged."))
}

@Test func shorterInstructionsInFrenchArePinnedVerbatim() {
    #expect(Prompts.instructions(.shorter, .fr) == """
        You are an editor. Rewrite the user's text so it is shorter and to the point. \
        Keep its meaning, its facts, its names and its language. \
        Reply with the rewritten text only. The text is written in French. Reply in French.
        """)
}

@Test func eachRewriteNamesItsGoal() {
    let goals: [EngineAction: String] = [
        .clearer: "so it is clearer and easier to read",
        .shorter: "so it is shorter and to the point",
        .moreFormal: "so it is more formal and polite",
        .friendlier: "so it is friendlier and warmer",
    ]
    for (action, goal) in goals {
        #expect(Prompts.instructions(action, .en) == """
            You are an editor. Rewrite the user's text \(goal). \
            Keep its meaning, its facts, its names and its language. \
            Reply with the rewritten text only. The text is written in English. Reply in English.
            """)
    }
}

@Test func confirmInstructionsNameTheLanguage() {
    #expect(Prompts.instructions(.confirm, .nl) == """
        You check one proposed change in a Dutch text. \
        Answer yes if the original words are an error and the change corrects it. \
        Answer no if the original words were already correct and the change only rewords, translates or changes tense or style. \
        Reply with yes or no only.
        """)
}

@Test func theConfirmPromptLaysOutTextOriginalAndChange() {
    let request = EngineRequest(
        action: .confirm, language: .en, text: "I has a dog.",
        confirmOriginal: "has", confirmReplacement: "have"
    )
    #expect(Prompts.prompt(request) == "Text: I has a dog.\nOriginal: has\nChange to: have")
}

@Test func everyOtherActionPromptsWithTheTextItself() {
    for action in EngineAction.allCases where action != .confirm {
        let request = EngineRequest(action: action, language: .fr, text: "Bonjour\nle monde")
        #expect(Prompts.prompt(request) == "Bonjour\nle monde")
    }
}

@Test func confirmInstructionsUseTheRightArticleForEachLanguage() {
    #expect(Prompts.instructions(.confirm, .en) == """
        You check one proposed change in an English text. \
        Answer yes if the original words are an error and the change corrects it. \
        Answer no if the original words were already correct and the change only rewords, translates or changes tense or style. \
        Reply with yes or no only.
        """)
    #expect(Prompts.instructions(.confirm, .fr).hasPrefix("You check one proposed change in a French text. "))
}
