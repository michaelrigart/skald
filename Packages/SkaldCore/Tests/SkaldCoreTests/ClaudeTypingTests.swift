import Foundation
import Testing
@testable import SkaldCore
import SkaldCoreTestSupport
import struct SkaldCore.Issue

private let mail = "com.example.mail"
private let dutch = "Ik heb de fix gisterren nagekeken en het word morgen uitgerold"
private let dutch2 = "Ik heb gisterren ook de logs bekeken"
private let french = "J'ai vérifié les serveur ce matin et tout marche"
private let french2 = "J'ai aussi regardé les journaux hier soir"
private let flew = "We flew to teh office in paris yesterday"
private let corrections = ["gisterren": "gisteren", "word": "wordt", "serveur": "serveurs"]

private func claudeSettings(_ change: (inout Settings) -> Void = { _ in }) -> Settings {
    var settings = Settings()
    settings.claudeTyping = true
    change(&settings)
    return settings
}

private func makeRig(
    _ settings: Settings = claudeSettings(),
    claude: FakeEngine = .correcting(corrections),
    key: Bool = true
) -> PipelineRig {
    PipelineRig(settings, claude: claude, key: key, misspellings: ["gisterren": "gisteren", "teh": "the"])
}

private func units(_ text: String) -> Int {
    text.utf16.count
}

/// Waits until the Claude fake has seen `count` calls end cancelled; a late call ends on its own task.
private func waitForCancelled(_ claude: FakeEngine, _ count: Int) async {
    while await claude.cancelled.count < count { await Task.yield() }
}

/// Holds the first route lookup of kind `.model` for Dutch until released.
private actor LookupHold {
    private var gate = CallGate(closed: true)

    func arrive(_ language: Language, _ lookup: RouteLookup) async {
        guard language == .nl, lookup == .model else { return }
        let index = gate.arrive()
        if index == 0, gate.mustWait(0) {
            await withCheckedContinuation { gate.hold(0, $0) }
        }
    }

    func waitForLookup() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate.wait(id, for: 1, $0) }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: UUID) {
        gate.stopWaiting(id)
    }

    func release() {
        gate.release(0)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ClaudeTypingTests {
    @Test func aDutchParagraphGoesToClaudeAndOnlyItsTextIsSent() async throws {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claude: claude)
        await rig.focus(dutch + "\n" + dutch2, caret: 3)
        await rig.check()

        let requests = await claude.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.action == .check)
        #expect(request.language == .nl)
        #expect(request.text == dutch)
        #expect(request.confirmOriginal == nil)
        #expect(request.confirmReplacement == nil)
        #expect(rig.claudeModels.models == ["claude-haiku-5-5"])
        #expect(await rig.engine.requests.isEmpty)
        let issues = await rig.modelIssues()
        #expect(issues.map(\.word) == ["gisterren", "word"])
        #expect(issues.map(\.engine) == [.claude, .claude])
    }

    @Test func dutchSpellingShowsAtOnceAndClaudeWithdrawsWhatItLeftAlone() async {
        let claude = FakeEngine.correcting(["word": "wordt"], gated: true)
        let rig = makeRig(claude: claude)
        var published = rig.pipeline.issues.makeAsyncIterator()
        await rig.focus(dutch + "\n" + dutch2, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)
        let shown = await PipelineRig.next(&published) { $0.issues.filter { $0.source == .spelling }.count == 2 }
        #expect(shown?.issues.map(\.parent.text) == [dutch, dutch2])
        #expect(shown?.issues.map(\.word) == ["gisterren", "gisterren"])

        await claude.open()
        await rig.pipeline.drain()
        let issues = await rig.visible()
        #expect(issues.filter { $0.source == .spelling }.map(\.parent.text) == [dutch2])
        #expect(issues.filter { $0.source == .model }.map(\.word) == ["word"])
        #expect(issues.filter { $0.source == .model }.map(\.engine) == [.claude])
        #expect(await claude.texts == [dutch])
    }

    @Test func aFrenchParagraphShowsNothingUntilClaudeAnswers() async {
        let claude = FakeEngine.correcting(corrections, gated: true)
        let rig = makeRig(claude: claude)
        await rig.focus(french + "\n" + french2, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)
        #expect(await rig.visible().isEmpty)
        #expect(await rig.spelling.texts.isEmpty)

        await claude.open()
        await rig.pipeline.drain()
        let issues = await rig.visible()
        #expect(issues.map(\.word) == ["serveur"])
        #expect(issues.map(\.engine) == [.claude])
        #expect(await claude.texts == [french])
    }

    private func answeredFrench() async -> (PipelineRig, FakeEngine) {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claude: claude)
        await rig.focus(french + "\n" + french2, caret: 3)
        await rig.check()
        return (rig, claude)
    }

    @Test func claudesFrenchIssuesSurviveTheCaretLeavingAndComingBack() async {
        let (rig, claude) = await answeredFrench()
        let inFrench2 = units(french) + 1 + 3

        await rig.access.moveCaret(to: inFrench2, in: PipelineRig.fieldA)
        await rig.recheckAtCaret()
        #expect(await claude.texts == [french, french2])

        await rig.access.moveCaret(to: 3, in: PipelineRig.fieldA)
        await rig.recheckAtCaret()
        await rig.access.moveCaret(to: 5, in: PipelineRig.fieldA)
        await rig.recheckAtCaret()
        #expect(await claude.texts == [french, french2])
        let issues = await rig.visible()
        #expect(issues.map(\.word) == ["serveur"])
        #expect(issues.map(\.engine) == [.claude])
    }

    @Test func claudesFrenchIssuesSurviveARefocus() async {
        let (rig, claude) = await answeredFrench()
        await rig.access.moveCaret(to: units(french) + 1 + 3, in: PipelineRig.fieldA)
        await rig.recheckAtCaret()
        #expect(await claude.texts == [french, french2])

        await rig.focus("ok", in: PipelineRig.fieldB)
        await rig.pipeline.receive(.focused(PipelineRig.fieldA))
        await rig.check()
        let issues = await rig.visible()
        #expect(issues.map(\.word) == ["serveur"])
        #expect(issues.map(\.engine) == [.claude])
        #expect(await claude.texts == [french, french2])
    }

    @Test func englishStaysOnTheMac() async {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claude: claude)
        await rig.focus(flew, caret: 3)
        await rig.check()

        #expect(await rig.engine.texts == [flew])
        #expect(await claude.requests.isEmpty)
        let issues = await rig.modelIssues()
        #expect(!issues.isEmpty)
        #expect(issues.allSatisfy { $0.engine == .thisMac })
    }

    @Test func anAppKeptOnThisMacSendsNothing() async {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claudeSettings { $0.appOverrides[mail] = .thisMacOnly }, claude: claude)
        await rig.focus(dutch, caret: 3)
        await rig.check()

        #expect(await claude.requests.isEmpty)
        #expect(await rig.visible().map(\.word) == ["gisterren"])
    }

    @Test func nothingIsSentWhilePaused() async {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claude: claude)
        await rig.pipeline.setPaused(true)
        await rig.focus(dutch, caret: 3)
        await rig.pipeline.receive(.edited(PipelineRig.fieldA))
        await rig.check()

        #expect(await claude.requests.isEmpty)
        #expect(await rig.visible().isEmpty)
    }

    @Test func withoutAKeyDutchIsSpellingOnly() async {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claude: claude, key: false)
        await rig.focus(dutch, caret: 3)
        await rig.check()

        #expect(await claude.requests.isEmpty)
        #expect(await rig.visible().map(\.word) == ["gisterren"])
    }

    @Test(arguments: ["", "unknown"])
    func aFieldWithoutABundleIdentifierSendsNothing(_ app: String) async {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claude: claude)
        let field = FieldID(app: app, token: "x")
        await rig.focus(dutch, caret: 3, in: field)
        await rig.check()

        #expect(await claude.requests.isEmpty)
        #expect(await rig.visible(in: field).map(\.word) == ["gisterren"])
    }

    @Test func aNewerPauseCancelsTheRunningRequest() async {
        let claude = FakeEngine.correcting(corrections, gated: true)
        let rig = makeRig(claude: claude)
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)

        let edited = dutch + " nu"
        await rig.access.set(edited, caret: 3, in: PipelineRig.fieldA)
        await rig.pipeline.receive(.edited(PipelineRig.fieldA))
        rig.pass()
        await claude.waitForRequests(2)
        #expect(await claude.texts == [dutch, edited])

        await claude.open()
        await rig.pipeline.drain()
        await waitForCancelled(claude, 1)
        #expect(await claude.cancelled == [0])
        let issues = await rig.modelIssues()
        #expect(issues.map(\.word) == ["gisterren", "word"])
        #expect(issues.allSatisfy { $0.chunk.text == edited })
    }

    @Test func anAnswerWithinTheTimeoutIsUsed() async {
        let claude = FakeEngine.correcting(corrections, gated: true)
        let rig = makeRig(claude: claude)
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)

        rig.clock.advance(by: .milliseconds(4_999))
        await claude.open()
        await rig.pipeline.drain()
        #expect(await rig.modelIssues().map(\.word) == ["gisterren", "word"])
    }

    @Test func anAnswerAfterTheTimeoutIsIgnored() async {
        let claude = FakeEngine.correcting(corrections, gated: true)
        let rig = makeRig(claude: claude)
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)

        rig.clock.advance(by: CheckPipeline.claudeTimeout)
        await rig.pipeline.drain()
        await claude.open()
        await waitForCancelled(claude, 1)
        await rig.pipeline.drain()
        #expect(await rig.modelIssues().isEmpty)
        #expect(await claude.cancelled == [0])
    }

    @Test func confirmationStaysOnThisMacForAClaudeAnswer() async {
        let text = "Ik heb de fix voor paris klaar gezet vandaag"
        let settings = claudeSettings()
        #expect(settings.modelChecks[.nl] == false)

        let confirming = makeRig(settings, claude: .correcting(["paris": "Paris"]))
        await confirming.focus(text, caret: 3)
        await confirming.check()
        #expect(await confirming.confirmer.asked == ["paris"])
        #expect(await confirming.modelIssues().map(\.word) == ["paris"])

        let withoutApple = makeRig(settings, claude: .correcting(["paris": "Paris"]))
        await withoutApple.update(settings, apple: .appleIntelligenceOff)
        await withoutApple.focus(text, caret: 3)
        await withoutApple.check()
        #expect(await withoutApple.confirmer.asked.isEmpty)
        #expect(await withoutApple.modelIssues().isEmpty)
    }

    @Test func anAnswerArrivingAfterTheSwitchWentOffIsDropped() async {
        let claude = FakeEngine.correcting(corrections, gated: true)
        let rig = makeRig(claude: claude)
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)

        await rig.update(claudeSettings { $0.claudeTyping = false })
        await claude.open()
        await rig.pipeline.drain()
        await rig.check()
        #expect(await rig.modelIssues().isEmpty)
        #expect(await claude.texts == [dutch])
    }

    @Test func aPauseBeforeTheSendSendsNothing() async {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claude: claude)
        let hold = LookupHold()
        await rig.pipeline.setRouteHook { language, lookup in await hold.arrive(language, lookup) }
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await hold.waitForLookup()

        await rig.pipeline.setPaused(true)
        await hold.release()
        await rig.pipeline.drain()
        #expect(await claude.requests.isEmpty)
        #expect(await rig.modelIssues().isEmpty)
    }

    @Test func keepingTheAppOnThisMacBeforeTheSendSendsNothing() async {
        let claude = FakeEngine.correcting(corrections)
        let rig = makeRig(claude: claude)
        let hold = LookupHold()
        await rig.pipeline.setRouteHook { language, lookup in await hold.arrive(language, lookup) }
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await hold.waitForLookup()

        await rig.update(claudeSettings { $0.appOverrides[mail] = .thisMacOnly })
        await hold.release()
        await rig.pipeline.drain()
        await rig.check()
        #expect(await claude.requests.isEmpty)
        #expect(await rig.visible().map(\.word) == ["gisterren"])
    }

    @Test func turningClaudeOnRechecksTheField() async {
        let claude = FakeEngine.correcting(corrections)
        let off = claudeSettings { $0.claudeTyping = false }
        let rig = makeRig(off, claude: claude)
        await rig.focus(dutch, caret: 3)
        await rig.check()
        #expect(await claude.requests.isEmpty)

        await rig.update(claudeSettings())
        await rig.check()
        #expect(await claude.texts == [dutch])
    }
}
