import AppKit
import Foundation
import SkaldCore
import Testing
@testable import Skald

private let utc = TimeZone(identifier: "UTC")!
private let british = Locale(identifier: "en_GB")
/// 2026-11-06 14:30:00 UTC.
private let halfPastTwo = Date(timeIntervalSince1970: 1_793_975_400)

@Test func eachStateHasItsTitle() {
    #expect(StatusState.on.title(locale: british, timeZone: utc) == "Skald is on")
    #expect(StatusState.paused(until: halfPastTwo).title(locale: british, timeZone: utc) == "Paused until 14:30")
    #expect(StatusState.spellingOnly(.appleIntelligenceOff).title(locale: british, timeZone: utc)
        == "Spelling only: Apple Intelligence is off")
    #expect(StatusState.spellingOnly(.thermalPause).title(locale: british, timeZone: utc)
        == "Spelling only: paused while this Mac is hot")
    #expect(StatusState.noAccessibility.title(locale: british, timeZone: utc) == "Skald needs Accessibility access")
}

@Test func everyReasonHasItsOwnFixedText() {
    let reasons: [UnavailableReason] = [
        .appleIntelligenceOff, .deviceNotEligible, .modelNotReady, .thermalPause, .languageOff,
        .studioNotConfigured, .studioUnreachable, .claudeKeyMissing,
    ]
    let texts = reasons.map(\.explanation)
    #expect(Set(texts).count == reasons.count)
    #expect(texts.allSatisfy { !$0.isEmpty })
    #expect(UnavailableReason.modelNotReady.explanation == "Apple's model isn't ready yet")
}

@Test func missingAccessibilityOutranksEverythingElse() {
    let state = StatusState.resolve(
        trusted: false, pausedUntil: halfPastTwo, now: halfPastTwo.addingTimeInterval(-60),
        apple: .appleIntelligenceOff, thermalPaused: true
    )
    #expect(state == .noAccessibility)
}

@Test func aPauseInTheFutureOutranksSpellingOnly() {
    let state = StatusState.resolve(
        trusted: true, pausedUntil: halfPastTwo, now: halfPastTwo.addingTimeInterval(-60),
        apple: .appleIntelligenceOff, thermalPaused: false
    )
    #expect(state == .paused(until: halfPastTwo))
}

@Test func aPauseThatHasEndedNoLongerCounts() {
    let state = StatusState.resolve(trusted: true, pausedUntil: halfPastTwo, now: halfPastTwo, apple: nil, thermalPaused: false)
    #expect(state == .on)
}

@Test func appleUnavailabilityOutranksTheThermalPause() {
    let apple = StatusState.resolve(trusted: true, pausedUntil: nil, now: halfPastTwo, apple: .modelNotReady, thermalPaused: true)
    #expect(apple == .spellingOnly(.modelNotReady))
    let hot = StatusState.resolve(trusted: true, pausedUntil: nil, now: halfPastTwo, apple: nil, thermalPaused: true)
    #expect(hot == .spellingOnly(.thermalPause))
}

@Test func everyStateShowsTheMenuBarGlyphAsATemplateDescribedByItsTitle() throws {
    let states: [StatusState] = [.on, .paused(until: halfPastTwo), .spellingOnly(.thermalPause), .noAccessibility]
    let shared = try #require(NSImage(named: StatusState.glyphName))
    for state in states {
        let image = try #require(state.image())
        #expect(image.isTemplate)
        #expect(image.accessibilityDescription == state.title())
    }
    #expect(Set(states.map { $0.title() }).count == states.count)
    #expect(shared.accessibilityDescription == nil)
}

@Test func theTestHostBuildsNoCompositionRoot() throws {
    let delegate = try #require(NSApp.delegate as? AppDelegate)
    #expect(delegate.root == nil)
}
