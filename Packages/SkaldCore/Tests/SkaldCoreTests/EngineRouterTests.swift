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
    for language in Language.allCases {
        settings.modelChecks[language] = true
        settings.typingChecks[language] = true
    }
    configure(&settings)
    return EngineRouter(settings: settings, appleAvailability: apple, thermalPaused: thermalPaused, claudeKeyPresent: key)
}

@Test func typingUsesTheModelWhenEverythingIsAvailable() {
    let router = router()
    for language in Language.allCases { #expect(router.onDevice(language) == .model) }
}

@Test func typingIsOffWhenTypingChecksAreOffForThatLanguageOnly() {
    let router = router(configure: { $0.typingChecks[.nl] = false })
    #expect(router.onDevice(.nl) == .off)
    #expect(router.onDevice(.en) == .model)
    #expect(router.onDevice(.fr) == .model)
}

@Test func typingChecksOffWinsOverEveryOtherReason() {
    let router = router(configure: { $0.typingChecks[.fr] = false; $0.modelChecks[.fr] = false }, apple: .modelNotReady, thermalPaused: true)
    #expect(router.onDevice(.fr) == .off)
}

@Test func typingFallsBackToSpellingOnlyWithAppleReason() {
    for reason in [UnavailableReason.appleIntelligenceOff, .deviceNotEligible, .modelNotReady] {
        let router = router(apple: reason)
        for language in Language.allCases { #expect(router.onDevice(language) == .spellingOnly(reason)) }
    }
}

@Test func appleReasonWinsOverThermalPauseAndLanguageOff() {
    let router = router(configure: { $0.modelChecks[.en] = false }, apple: .appleIntelligenceOff, thermalPaused: true)
    #expect(router.onDevice(.en) == .spellingOnly(.appleIntelligenceOff))
}

@Test func typingFallsBackToSpellingOnlyOnThermalPause() {
    let router = router(configure: { $0.modelChecks[.fr] = false }, thermalPaused: true)
    #expect(router.onDevice(.en) == .spellingOnly(.thermalPause))
    #expect(router.onDevice(.fr) == .spellingOnly(.thermalPause))
}

@Test func typingFallsBackToSpellingOnlyForALanguageWithModelChecksOff() {
    let router = router(configure: { $0.modelChecks[.nl] = false })
    #expect(router.onDevice(.nl) == .spellingOnly(.languageOff))
    #expect(router.onDevice(.en) == .model)
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
                if case .spellingOnly(let reason) = router.onDevice(language) {
                    #expect(!remoteReasons.contains(reason))
                }
            }
        }
    }
}

@Test func panelUsesTheDefaultEngineWhenNoneIsRequested() {
    #expect(router().panel(requested: nil, app: nil) == .use(.thisMac))
    #expect(router(configure: { $0.panelDefaultEngine = .claude }, key: true).panel(requested: nil, app: nil) == .use(.claude))
}

@Test func panelNeverPicksClaudeUnaskedEvenWithAKeyAndStudioConfigured() {
    let router = router(configure: { $0.panelDefaultEngine = .thisMac; $0.studio = studio }, key: true)
    #expect(router.panel(requested: nil, app: nil) == .use(.thisMac))
}

@Test func alternativesListEveryOtherUsableEngineInOrder() {
    let full = router(configure: { $0.studio = studio }, key: true)
    #expect(full.alternatives(to: .macStudio, app: nil) == [.thisMac, .claude])
    #expect(full.alternatives(to: .thisMac, app: nil) == [.macStudio, .claude])
    #expect(full.alternatives(to: .claude, app: nil) == [.thisMac, .macStudio])
    #expect(router(configure: { $0.studio = studio }, apple: .appleIntelligenceOff).alternatives(to: .claude, app: nil) == [.macStudio])
}

@Test func panelPrefersTheRequestedEngineOverTheDefault() {
    let router = router(configure: { $0.panelDefaultEngine = .claude; $0.studio = studio }, key: true)
    #expect(router.panel(requested: .thisMac, app: nil) == .use(.thisMac))
    #expect(router.panel(requested: .macStudio, app: nil) == .use(.macStudio))
}

@Test func panelStudioNotConfiguredOffersThisMacAndClaudeWithAKey() {
    #expect(router(key: true).panel(requested: .macStudio, app: nil) == .unavailable(.macStudio, .studioNotConfigured, alternatives: [.thisMac, .claude]))
    #expect(router(key: false).panel(requested: .macStudio, app: nil) == .unavailable(.macStudio, .studioNotConfigured, alternatives: [.thisMac]))
}

@Test func panelClaudeWithoutAKeyIsUnavailableAndOffersTheOthers() {
    let plain = router()
    #expect(plain.panel(requested: .claude, app: nil) == .unavailable(.claude, .claudeKeyMissing, alternatives: [.thisMac]))
    let configured = router(configure: { $0.studio = studio })
    #expect(configured.panel(requested: .claude, app: nil) == .unavailable(.claude, .claudeKeyMissing, alternatives: [.thisMac, .macStudio]))
}

@Test func panelThisMacUnavailableGivesAppleReasonAndTheRemoteAlternatives() {
    let router = router(configure: { $0.studio = studio }, apple: .deviceNotEligible, key: true)
    #expect(router.panel(requested: .thisMac, app: nil) == .unavailable(.thisMac, .deviceNotEligible, alternatives: [.macStudio, .claude]))
    let bare = EngineRouter(settings: Settings(), appleAvailability: .modelNotReady, thermalPaused: false, claudeKeyPresent: false)
    #expect(bare.panel(requested: .thisMac, app: nil) == .unavailable(.thisMac, .modelNotReady, alternatives: []))
}

@Test func panelThisMacIgnoresAThermalPause() {
    #expect(router(thermalPaused: true).panel(requested: .thisMac, app: nil) == .use(.thisMac))
}

@Test func panelAlternativesLeaveOutAnUnavailableThisMac() {
    let router = router(apple: .appleIntelligenceOff, key: true)
    #expect(router.panel(requested: .macStudio, app: nil) == .unavailable(.macStudio, .studioNotConfigured, alternatives: [.claude]))
}

@Test func panelDefaultThatIsUnavailableIsReportedForTheDefault() {
    let router = router(configure: { $0.panelDefaultEngine = .claude })
    #expect(router.panel(requested: nil, app: nil) == .unavailable(.claude, .claudeKeyMissing, alternatives: [.thisMac]))
}

@Test func pickerListsStudioOnlyWhenConfiguredAndAlwaysClaude() {
    #expect(router().pickerEngines(app: nil) == [.thisMac, .claude])
    #expect(router(configure: { $0.studio = studio }).pickerEngines(app: nil) == [.thisMac, .macStudio, .claude])
    #expect(router(configure: { $0.studio = studio }, apple: .appleIntelligenceOff).pickerEngines(app: nil) == [.thisMac, .macStudio, .claude])
}

@Test func liveRouterReflectsTheCurrentRouterAndGatesOnTyping() async {
    let live = LiveRouter(router())
    #expect(await live.modelAllowed(.en))
    await live.set(router(thermalPaused: true))
    #expect(await live.modelAllowed(.en) == false)
    #expect(await live.current.onDevice(.en) == .spellingOnly(.thermalPause))
    await live.set(router(configure: { $0.modelChecks[.nl] = false }))
    #expect(await live.modelAllowed(.nl) == false)
    #expect(await live.modelAllowed(.fr))
    await live.set(router(configure: { $0.typingChecks[.fr] = false }))
    #expect(await live.modelAllowed(.fr) == false)
}

private let mail = "com.example.mail"
private let chat = "com.example.chat"

private func claudeRouter(
    configure: (inout Settings) -> Void = { _ in },
    apple: UnavailableReason? = nil,
    thermalPaused: Bool = false,
    key: Bool = true
) -> EngineRouter {
    var settings = Settings()
    settings.claudeTyping = true
    configure(&settings)
    return EngineRouter(settings: settings, appleAvailability: apple, thermalPaused: thermalPaused, claudeKeyPresent: key)
}

@Test func theSwitchOffKeepsEveryLanguageOnThisMac() {
    let router = claudeRouter(configure: { $0.claudeTyping = false })
    #expect(router.typing(.nl, app: mail) == .spellingOnly(.languageOff))
    #expect(router.typing(.fr, app: mail) == .off)
    #expect(router.typing(.en, app: mail) == .model)
}

@Test func aTickedLanguageGoesToClaude() {
    let router = claudeRouter()
    #expect(router.typing(.nl, app: mail) == .claude)
    #expect(router.typing(.fr, app: mail) == .claude)
}

@Test func anUntickedLanguageStaysOnThisMac() {
    let router = claudeRouter(configure: { $0.claudeLanguages[.fr] = false })
    #expect(router.typing(.fr, app: mail) == .off)
    #expect(router.typing(.nl, app: mail) == .claude)
}

@Test func englishNeverGoesToClaude() {
    let router = claudeRouter(configure: { $0.claudeLanguages[.en] = true })
    #expect(router.typing(.en, app: mail) == .model)
    #expect(router.claudeTypingLanguages == [.nl, .fr])
}

@Test func anAppKeptOnThisMacKeepsItsTyping() {
    let router = claudeRouter(configure: { $0.appOverrides[mail] = .thisMacOnly })
    #expect(router.typing(.nl, app: mail) == .spellingOnly(.languageOff))
    #expect(router.typing(.fr, app: mail) == .off)
    #expect(router.typing(.nl, app: chat) == .claude)
}

@Test(arguments: ["", FieldID.unknownApp])
func anAppWithoutABundleIdentifierNeverGoesToClaude(_ app: String) {
    let router = claudeRouter()
    #expect(router.typing(.nl, app: app) == .spellingOnly(.languageOff))
    #expect(router.typing(.fr, app: app) == .off)
}

@Test func onlyAnAppThatIsOnGoesToClaude() {
    let ghostty = "com.mitchellh.ghostty"
    #expect(Settings.defaultMode(app: ghostty) == .off)
    let router = claudeRouter(configure: {
        $0.modelChecks[.nl] = true
        $0.appOverrides[mail] = .off
    })
    #expect(router.typing(.nl, app: mail) == .model)
    #expect(router.typing(.nl, app: ghostty) == .model)
    #expect(router.typing(.nl, app: chat) == .claude)
}

@Test func withoutAKeyNothingGoesToClaude() {
    let router = claudeRouter(key: false)
    #expect(router.typing(.nl, app: mail) == .spellingOnly(.languageOff))
    #expect(router.claudeTypingLanguages == [])
}

@Test func theOnDeviceSwitchesAreNotReadForARoutedLanguage() {
    let router = claudeRouter(
        configure: { $0.typingChecks[.fr] = false; $0.modelChecks[.fr] = false },
        apple: .appleIntelligenceOff, thermalPaused: true
    )
    #expect(router.typing(.fr, app: mail) == .claude)
    #expect(router.onDevice(.fr) == .off)
}

@Test func confirmingOnDeviceNeedsAppleAndNoThermalPause() {
    #expect(router().canConfirmOnDevice)
    #expect(router(apple: .modelNotReady).canConfirmOnDevice == false)
    #expect(router(thermalPaused: true).canConfirmOnDevice == false)
}

@Test func anAppKeptOnThisMacOffersOnlyThisMacInThePanel() {
    let router = router(
        configure: { $0.panelDefaultEngine = .claude; $0.studio = studio; $0.appOverrides[chat] = .thisMacOnly }, key: true
    )
    #expect(router.pickerEngines(app: chat) == [.thisMac])
    #expect(router.panelDefault(app: chat) == .thisMac)
    #expect(router.panel(requested: nil, app: chat) == .use(.thisMac))
    #expect(router.panel(requested: .claude, app: chat) == .unavailable(.claude, .keptOnThisMac, alternatives: [.thisMac]))
    #expect(router.panel(requested: .macStudio, app: chat) == .unavailable(.macStudio, .keptOnThisMac, alternatives: [.thisMac]))
    #expect(router.alternatives(to: .thisMac, app: chat) == [])
    #expect(router.alternatives(to: .claude, app: chat) == [.thisMac])
    #expect(router.pickerEngines(app: mail) == [.thisMac, .macStudio, .claude])
    #expect(router.panelDefault(app: mail) == .claude)
    #expect(router.pickerEngines(app: nil) == router.pickerEngines(app: mail))
}

@Test func aKeptAppWithoutAppleHasNoPanelEngine() {
    let router = router(configure: { $0.appOverrides[chat] = .thisMacOnly }, apple: .appleIntelligenceOff, key: true)
    #expect(router.panel(requested: nil, app: chat) == .unavailable(.thisMac, .appleIntelligenceOff, alternatives: []))
    #expect(router.panel(requested: .claude, app: chat) == .unavailable(.claude, .keptOnThisMac, alternatives: []))
}
