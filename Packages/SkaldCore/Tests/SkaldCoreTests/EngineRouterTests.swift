import Testing
@testable import SkaldCore

private let studio = StudioEndpoint(api: .ollama, baseURL: "http://studio.local:11434", model: "qwen")

private func router(
    configure: (inout Settings) -> Void = { _ in },
    apple: UnavailableReason? = nil,
    thermalPaused: Bool = false,
    key: Bool = false
) -> EngineRouter {
    var settings = Settings()
    configure(&settings)
    return EngineRouter(settings: settings, appleAvailability: apple, thermalPaused: thermalPaused, claudeKeyPresent: key)
}

@Test func typingUsesTheModelWhenEverythingIsAvailable() {
    let router = router()
    for language in Language.allCases { #expect(router.typing(language) == .model) }
}

@Test func typingIsOffWhenTypingChecksAreOffForThatLanguageOnly() {
    let router = router(configure: { $0.typingChecks[.nl] = false })
    #expect(router.typing(.nl) == .off)
    #expect(router.typing(.en) == .model)
    #expect(router.typing(.fr) == .model)
}

@Test func typingChecksOffWinsOverEveryOtherReason() {
    let router = router(configure: { $0.typingChecks[.fr] = false; $0.modelChecks[.fr] = false }, apple: .modelNotReady, thermalPaused: true)
    #expect(router.typing(.fr) == .off)
}

@Test func typingFallsBackToSpellingOnlyWithAppleReason() {
    for reason in [UnavailableReason.appleIntelligenceOff, .deviceNotEligible, .modelNotReady] {
        let router = router(apple: reason)
        for language in Language.allCases { #expect(router.typing(language) == .spellingOnly(reason)) }
    }
}

@Test func appleReasonWinsOverThermalPauseAndLanguageOff() {
    let router = router(configure: { $0.modelChecks[.en] = false }, apple: .appleIntelligenceOff, thermalPaused: true)
    #expect(router.typing(.en) == .spellingOnly(.appleIntelligenceOff))
}

@Test func typingFallsBackToSpellingOnlyOnThermalPause() {
    let router = router(configure: { $0.modelChecks[.fr] = false }, thermalPaused: true)
    #expect(router.typing(.en) == .spellingOnly(.thermalPause))
    #expect(router.typing(.fr) == .spellingOnly(.thermalPause))
}

@Test func typingFallsBackToSpellingOnlyForALanguageWithModelChecksOff() {
    let router = router(configure: { $0.modelChecks[.nl] = false })
    #expect(router.typing(.nl) == .spellingOnly(.languageOff))
    #expect(router.typing(.en) == .model)
}

@Test func noTypingResultNamesARemoteEngineOrARemoteReason() {
    var settings = Settings()
    settings.panelDefaultEngine = .claude
    settings.studio = studio
    let remoteReasons: Set<UnavailableReason> = [.studioNotConfigured, .studioUnreachable, .claudeKeyMissing]
    for apple in [nil, UnavailableReason.appleIntelligenceOff, .deviceNotEligible, .modelNotReady] {
        for thermal in [false, true] {
            let router = EngineRouter(settings: settings, appleAvailability: apple, thermalPaused: thermal, claudeKeyPresent: true)
            for language in Language.allCases {
                if case .spellingOnly(let reason) = router.typing(language) {
                    #expect(!remoteReasons.contains(reason))
                }
            }
        }
    }
}

@Test func panelUsesTheDefaultEngineWhenNoneIsRequested() {
    #expect(router().panel(requested: nil) == .use(.thisMac))
    #expect(router(configure: { $0.panelDefaultEngine = .claude }, key: true).panel(requested: nil) == .use(.claude))
}

@Test func panelNeverPicksClaudeUnaskedEvenWithAKeyAndStudioConfigured() {
    let router = router(configure: { $0.panelDefaultEngine = .thisMac; $0.studio = studio }, key: true)
    #expect(router.panel(requested: nil) == .use(.thisMac))
}

@Test func alternativesListEveryOtherUsableEngineInOrder() {
    let full = router(configure: { $0.studio = studio }, key: true)
    #expect(full.alternatives(to: .macStudio) == [.thisMac, .claude])
    #expect(full.alternatives(to: .thisMac) == [.macStudio, .claude])
    #expect(full.alternatives(to: .claude) == [.thisMac, .macStudio])
    #expect(router(configure: { $0.studio = studio }, apple: .appleIntelligenceOff).alternatives(to: .claude) == [.macStudio])
}

@Test func panelPrefersTheRequestedEngineOverTheDefault() {
    let router = router(configure: { $0.panelDefaultEngine = .claude; $0.studio = studio }, key: true)
    #expect(router.panel(requested: .thisMac) == .use(.thisMac))
    #expect(router.panel(requested: .macStudio) == .use(.macStudio))
}

@Test func panelStudioNotConfiguredOffersThisMacAndClaudeWithAKey() {
    #expect(router(key: true).panel(requested: .macStudio) == .unavailable(.macStudio, .studioNotConfigured, alternatives: [.thisMac, .claude]))
    #expect(router(key: false).panel(requested: .macStudio) == .unavailable(.macStudio, .studioNotConfigured, alternatives: [.thisMac]))
}

@Test func panelClaudeWithoutAKeyIsUnavailableAndOffersTheOthers() {
    let plain = router()
    #expect(plain.panel(requested: .claude) == .unavailable(.claude, .claudeKeyMissing, alternatives: [.thisMac]))
    let configured = router(configure: { $0.studio = studio })
    #expect(configured.panel(requested: .claude) == .unavailable(.claude, .claudeKeyMissing, alternatives: [.thisMac, .macStudio]))
}

@Test func panelThisMacUnavailableGivesAppleReasonAndTheRemoteAlternatives() {
    let router = router(configure: { $0.studio = studio }, apple: .deviceNotEligible, key: true)
    #expect(router.panel(requested: .thisMac) == .unavailable(.thisMac, .deviceNotEligible, alternatives: [.macStudio, .claude]))
    let bare = EngineRouter(settings: Settings(), appleAvailability: .modelNotReady, thermalPaused: false, claudeKeyPresent: false)
    #expect(bare.panel(requested: .thisMac) == .unavailable(.thisMac, .modelNotReady, alternatives: []))
}

@Test func panelThisMacIgnoresAThermalPause() {
    #expect(router(thermalPaused: true).panel(requested: .thisMac) == .use(.thisMac))
}

@Test func panelAlternativesLeaveOutAnUnavailableThisMac() {
    let router = router(apple: .appleIntelligenceOff, key: true)
    #expect(router.panel(requested: .macStudio) == .unavailable(.macStudio, .studioNotConfigured, alternatives: [.claude]))
}

@Test func panelDefaultThatIsUnavailableIsReportedForTheDefault() {
    let router = router(configure: { $0.panelDefaultEngine = .claude })
    #expect(router.panel(requested: nil) == .unavailable(.claude, .claudeKeyMissing, alternatives: [.thisMac]))
}

@Test func pickerListsStudioOnlyWhenConfiguredAndAlwaysClaude() {
    #expect(router().pickerEngines == [.thisMac, .claude])
    #expect(router(configure: { $0.studio = studio }).pickerEngines == [.thisMac, .macStudio, .claude])
    #expect(router(configure: { $0.studio = studio }, apple: .appleIntelligenceOff).pickerEngines == [.thisMac, .macStudio, .claude])
}

@Test func liveRouterReflectsTheCurrentRouterAndGatesOnTyping() async {
    let live = LiveRouter(router())
    #expect(await live.modelAllowed(.en))
    await live.set(router(thermalPaused: true))
    #expect(await live.modelAllowed(.en) == false)
    #expect(await live.current.typing(.en) == .spellingOnly(.thermalPause))
    await live.set(router(configure: { $0.modelChecks[.nl] = false }))
    #expect(await live.modelAllowed(.nl) == false)
    #expect(await live.modelAllowed(.fr))
    await live.set(router(configure: { $0.typingChecks[.fr] = false }))
    #expect(await live.modelAllowed(.fr) == false)
}
