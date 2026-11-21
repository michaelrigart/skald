import AppKit
import Foundation
import SkaldCore
import Testing
@testable import Skald

private let utc = TimeZone(identifier: "UTC")!
private let british = Locale(identifier: "en_GB")
/// 2026-11-06 14:30:00 UTC.
private let halfPastTwo = Date(timeIntervalSince1970: 1_793_975_400)

private func resolve(
    trusted: Bool = true, pausedUntil: Date? = nil, now: Date = halfPastTwo, apple: UnavailableReason? = nil,
    thermalPaused: Bool = false, claude: ClaudeStatus = .quiet, claudeLanguages: [Language] = [],
    fallbacks: [ClaudeFallback] = []
) -> StatusState {
    StatusState.resolve(
        trusted: trusted, pausedUntil: pausedUntil, now: now, apple: apple, thermalPaused: thermalPaused,
        claude: claude, claudeLanguages: claudeLanguages, fallbacks: fallbacks
    )
}

@Test func eachStateHasItsTitle() {
    #expect(StatusState.onThisMac.title(locale: british, timeZone: utc) == "Checking on this Mac")
    #expect(StatusState.paused(until: halfPastTwo).title(locale: british, timeZone: utc) == "Paused until 14:30")
    #expect(StatusState.spellingOnly(.appleIntelligenceOff).title(locale: british, timeZone: utc)
        == "Spelling only: Apple Intelligence is off")
    #expect(StatusState.spellingOnly(.thermalPause).title(locale: british, timeZone: utc)
        == "Spelling only: paused while this Mac is hot")
    #expect(StatusState.noAccessibility.title(locale: british, timeZone: utc) == "Skald needs Accessibility access")
}

@Test func claudeStatesNameTheLanguagesAndWhatTheyFellBackTo() {
    #expect(StatusState.usingClaude([.nl, .fr], lastFailure: nil).title() == "Dutch and French checks use Claude")
    #expect(StatusState.usingClaude([.nl], lastFailure: nil).title() == "Dutch checks use Claude")
    #expect(StatusState.usingClaude([.fr], lastFailure: nil).title() == "French checks use Claude")
    #expect(StatusState.claudeTrouble(.unreachable, fallbacks: [.init(language: .nl, route: .spellingOnly(.languageOff)), .init(language: .fr, route: .off)]).title()
        == "Claude unreachable: Dutch is spelling only, French isn't checked while typing")
    #expect(StatusState.claudeTrouble(.keyRejected, fallbacks: [.init(language: .nl, route: .model)]).title()
        == "Claude has no valid API key: Dutch is checked on this Mac")
    #expect(StatusState.claudeTrouble(.rateLimited, fallbacks: []).title() == "Claude is limiting requests")
    #expect(StatusState.claudeTrouble(.declined, fallbacks: []).title() == "Claude declined a paragraph")
}

@Test func everyReasonHasItsOwnFixedText() {
    let reasons: [UnavailableReason] = [
        .appleIntelligenceOff, .deviceNotEligible, .modelNotReady, .thermalPause, .languageOff,
        .studioNotConfigured, .studioUnreachable, .claudeKeyMissing,
        .claudeKeyRejected, .claudeRateLimited, .keptOnThisMac,
    ]
    let texts = reasons.map(\.explanation)
    #expect(Set(texts).count == reasons.count)
    #expect(texts.allSatisfy { !$0.isEmpty })
    #expect(UnavailableReason.modelNotReady.explanation == "Apple's model isn't ready yet")
}

@Test func missingAccessibilityOutranksEverythingElse() {
    let state = resolve(
        trusted: false, pausedUntil: halfPastTwo, now: halfPastTwo.addingTimeInterval(-60),
        apple: .appleIntelligenceOff, thermalPaused: true,
        claude: ClaudeStatus(sending: true, trouble: .unreachable), claudeLanguages: [.nl]
    )
    #expect(state == .noAccessibility)
}

@Test func aPauseInTheFutureOutranksSpellingOnly() {
    let state = resolve(pausedUntil: halfPastTwo, now: halfPastTwo.addingTimeInterval(-60), apple: .appleIntelligenceOff)
    #expect(state == .paused(until: halfPastTwo))
}

@Test func aPauseThatHasEndedNoLongerCounts() {
    #expect(resolve(pausedUntil: halfPastTwo, now: halfPastTwo) == .onThisMac)
}

@Test func appleUnavailabilityOutranksTheThermalPause() {
    #expect(resolve(apple: .modelNotReady, thermalPaused: true) == .spellingOnly(.modelNotReady))
    #expect(resolve(thermalPaused: true) == .spellingOnly(.thermalPause))
}

@Test func claudeTroubleRanksBelowPauseAndAboveApple() {
    let fallbacks: [ClaudeFallback] = [.init(language: .nl, route: .model), .init(language: .fr, route: .off)]
    let trouble = ClaudeStatus(sending: false, trouble: .unreachable, suspended: true)
    #expect(resolve(pausedUntil: halfPastTwo.addingTimeInterval(60), claude: trouble, claudeLanguages: [.nl, .fr], fallbacks: fallbacks)
        == .paused(until: halfPastTwo.addingTimeInterval(60)))
    #expect(resolve(apple: .appleIntelligenceOff, claude: trouble, claudeLanguages: [.nl, .fr], fallbacks: fallbacks)
        == .claudeTrouble(.unreachable, fallbacks: fallbacks))
    #expect(resolve(apple: .appleIntelligenceOff, claude: ClaudeStatus(sending: true, trouble: nil), claudeLanguages: [.nl, .fr])
        == .usingClaude([.nl, .fr], lastFailure: nil))
    #expect(resolve(apple: .appleIntelligenceOff, claude: ClaudeStatus(sending: true, trouble: nil)) == .spellingOnly(.appleIntelligenceOff))
    #expect(resolve(claude: ClaudeStatus(sending: false, trouble: .rateLimited)) == .onThisMac)
    #expect(resolve(claude: ClaudeStatus(sending: false, trouble: nil), claudeLanguages: [.nl]) == .onThisMac)
}

@Test func troubleIsClaimedOnlyWhileClaudeIsSuspended() {
    let fallbacks: [ClaudeFallback] = [.init(language: .nl, route: .spellingOnly(.languageOff)), .init(language: .fr, route: .off)]
    let failedOnce = ClaudeStatus(sending: false, trouble: .unreachable, suspended: false)
    #expect(resolve(claude: failedOnce, claudeLanguages: [.nl, .fr], fallbacks: fallbacks) == .onThisMac)
    #expect(resolve(claude: failedOnce, claudeLanguages: [.nl, .fr], fallbacks: fallbacks).title() == "Checking on this Mac")
    #expect(resolve(claude: ClaudeStatus(sending: false, trouble: .unreachable, suspended: true), claudeLanguages: [.nl, .fr], fallbacks: fallbacks)
        == .claudeTrouble(.unreachable, fallbacks: fallbacks))
}

@Test func whileARequestCanLeaveTheFirstLineIsTheClaudeLineAndAFailureIsASecondOne() {
    let fallbacks: [ClaudeFallback] = [.init(language: .nl, route: .model)]
    let state = resolve(
        apple: .appleIntelligenceOff, claude: ClaudeStatus(sending: true, trouble: .declined),
        claudeLanguages: [.nl], fallbacks: fallbacks
    )
    #expect(state == .usingClaude([.nl], lastFailure: .declined))
    #expect(state.title() == "Dutch checks use Claude")
    #expect(state.detail == "Last check failed: Claude declined a paragraph")
    #expect(StatusState.usingClaude([.nl], lastFailure: nil).detail == nil)
    #expect(StatusState.claudeTrouble(.declined, fallbacks: fallbacks).detail == nil)
}

@Test func theNoteSaysWhereSkaldCantWork() {
    #expect(FieldAccessNote.resolve(unreadable: true, focused: false, capabilities: nil) == .cantRead)
    #expect(FieldAccessNote.resolve(unreadable: false, focused: true, capabilities: [.read, .fieldFrame]) == .badgeOnly)
    #expect(FieldAccessNote.resolve(unreadable: false, focused: true, capabilities: [.read]) == .cantShow)
    #expect(FieldAccessNote.resolve(unreadable: false, focused: true, capabilities: [.read, .rangeBounds, .fieldFrame]) == nil)
    #expect(FieldAccessNote.resolve(unreadable: false, focused: false, capabilities: nil) == nil)
    #expect(FieldAccessNote.cantRead.line == "Skald can't read text in this app")
    #expect(FieldAccessNote.badgeOnly.line == "Issues are listed at the badge here")
    #expect(FieldAccessNote.cantShow.line == "Skald can't show issues in this app")
}

@Test func theNoteIsTheFirstLineUnlessARequestCanLeave() {
    #expect(StatusState.onThisMac.menuLines(note: .badgeOnly) == ["Issues are listed at the badge here", "Checking on this Mac"])
    #expect(StatusState.onThisMac.menuLines(note: nil) == ["Checking on this Mac"])
    #expect(StatusState.usingClaude([.nl], lastFailure: .unreachable).menuLines(note: .badgeOnly)
        == ["Dutch checks use Claude", "Last check failed: Claude unreachable", "Issues are listed at the badge here"])
    #expect(StatusState.claudeTrouble(.unreachable, fallbacks: []).menuLines(note: .badgeOnly)
        == ["Issues are listed at the badge here", "Claude unreachable"])
    #expect(StatusState.noAccessibility.menuLines(note: .cantRead) == ["Skald needs Accessibility access"])
    #expect(StatusState.paused(until: halfPastTwo).menuLines(note: .cantRead).count == 1)
}

@Test func everyStateShowsTheMenuBarGlyphAsATemplateDescribedByItsTitle() throws {
    let states: [StatusState] = [
        .onThisMac, .usingClaude([.nl], lastFailure: nil), .claudeTrouble(.unreachable, fallbacks: []),
        .paused(until: halfPastTwo), .spellingOnly(.thermalPause), .noAccessibility,
    ]
    let shared = try #require(NSImage(named: StatusState.glyphName))
    let glyph = try #require(shared.tiffRepresentation)
    for state in states {
        let image = try #require(state.image(sendingToClaude: false))
        #expect(image.tiffRepresentation == glyph)
        #expect(image.isTemplate)
        #expect(image.accessibilityDescription == state.title())
    }
    #expect(Set(states.map { $0.title() }).count == states.count)
    #expect(shared.accessibilityDescription == nil)
}

@Test func theCloudGlyphShowsOnlyWhileSending() throws {
    let plain = try #require(NSImage(named: StatusState.glyphName)?.tiffRepresentation)
    let cloud = try #require(NSImage(named: StatusState.cloudGlyphName)?.tiffRepresentation)
    #expect(plain != cloud)
    let state = StatusState.usingClaude([.nl], lastFailure: nil)
    let sending = try #require(state.image(sendingToClaude: true))
    let quiet = try #require(state.image(sendingToClaude: false))
    #expect(sending.tiffRepresentation == cloud)
    #expect(quiet.tiffRepresentation == plain)
    #expect(sending.isTemplate)
    #expect(quiet.isTemplate)
    #expect(sending.accessibilityDescription == state.title())
}

@Test func theTestHostBuildsNoCompositionRoot() throws {
    let delegate = try #require(NSApp.delegate as? AppDelegate)
    #expect(delegate.root == nil)
}
