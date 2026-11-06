import Testing
@testable import SkaldPlatform27

private let slack = "com.tinyspeck.slackmacgap"
private let mail = "com.apple.mail"

/// Whether each read, timed out or not, marked the app.
private func marks(_ apps: inout UnresponsiveApps, _ timedOut: [Bool], app: String = slack) -> [Bool] {
    timedOut.map { apps.read(app, timedOut: $0) }
}

@Test func theThirdTimedOutReadInARowMarksTheAppOnce() {
    var apps = UnresponsiveApps()
    #expect(marks(&apps, [true, true]) == [false, false])
    #expect(!apps.isMarked(slack))
    #expect(marks(&apps, [true, true]) == [true, false])
    #expect(apps.isMarked(slack))
}

@Test func aReadThatAnswersEndsTheStreak() {
    var apps = UnresponsiveApps()
    #expect(marks(&apps, [true, true, false, true, true]) == [false, false, false, false, false])
    #expect(!apps.isMarked(slack))
}

@Test func activatingTheAppAgainClearsTheMarkAndTheStreak() {
    var apps = UnresponsiveApps()
    _ = marks(&apps, [true, true, true])
    apps.activated(slack)
    #expect(!apps.isMarked(slack))
    #expect(marks(&apps, [true, true, true]) == [false, false, true])
}

@Test func eachAppHasItsOwnStreak() {
    var apps = UnresponsiveApps()
    _ = marks(&apps, [true, true])
    #expect(marks(&apps, [true], app: mail) == [false])
    #expect(marks(&apps, [true]) == [true])
    #expect(!apps.isMarked(mail))
}
