import Foundation
import Testing
@testable import SkaldCore
import SkaldCoreTestSupport
import struct SkaldCore.Issue

private let mail = "com.example.mail"
private let dutch = "Ik heb de fix gisterren nagekeken en het word morgen uitgerold"
private let dutch2 = "Ik heb gisterren ook de logs bekeken"
private let french = "J'ai vérifié les serveur ce matin et tout marche"
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
    claude: any Engine,
    engine: FakeEngine = .correcting(["teh": "the"])
) -> PipelineRig {
    PipelineRig(settings, engine: engine, claude: claude, key: true, misspellings: ["gisterren": "gisteren", "teh": "the"])
}

private func failing(_ failure: EngineFailure = .failed) -> FakeEngine {
    FakeEngine { _, _ in .failure(failure) }
}

private func variant(_ number: Int) -> String {
    "\(dutch) \(number)"
}

/// Replaces the caret paragraph and lets the check run; with `time`, the check runs at that moment on the rig's clock.
private func type(_ text: String, in rig: PipelineRig, at time: Duration? = nil) async {
    if let time { rig.clock.advance(by: time - PipelineRig.pause - rig.clock.now.offset) }
    await rig.access.set(text, caret: 3, in: PipelineRig.fieldA)
    await rig.pipeline.receive(.edited(PipelineRig.fieldA))
    await rig.check()
}

private func status(_ rig: PipelineRig) async -> ClaudeStatus {
    await rig.pipeline.lastClaudeStatus
}

/// Answers like the fake and records the pipeline's Claude status as each request starts.
private final class StatusProbe: Engine, @unchecked Sendable { // reason: the fields are only touched under the lock
    let kind = EngineKind.claude
    private let inner = FakeEngine.correcting(corrections)
    private let lock = NSLock()
    private var pipeline: CheckPipeline?
    private var recorded: [ClaudeStatus] = []

    var statuses: [ClaudeStatus] { lock.withLock { recorded } }

    func attach(_ pipeline: CheckPipeline) {
        lock.withLock { self.pipeline = pipeline }
    }

    func run(_ r: EngineRequest) async throws(EngineFailure) -> String {
        if let pipeline = lock.withLock({ pipeline }) {
            let seen = await pipeline.lastClaudeStatus
            lock.withLock { recorded.append(seen) }
        }
        return try await inner.run(r)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ClaudeFailureTests {
    @Test func theStatusSaysSendingBeforeTheRequestLeaves() async {
        let probe = StatusProbe()
        let rig = makeRig(claude: probe)
        probe.attach(rig.pipeline)
        await rig.focus(dutch, caret: 3)
        await rig.check()
        #expect(probe.statuses == [ClaudeStatus(sending: true, trouble: nil)])

        await rig.pipeline.setPaused(true)
        await rig.pipeline.drain()
        #expect(await status(rig).sending == false)

        let english = makeRig(claude: probe)
        await english.focus(flew, caret: 3)
        await english.check()
        #expect(await status(english).sending == false)

        let kept = makeRig(claudeSettings { $0.appOverrides[mail] = .thisMacOnly }, claude: probe)
        await kept.focus(dutch, caret: 3)
        await kept.check()
        #expect(await status(kept).sending == false)
        #expect(probe.statuses.count == 1)
    }

    @Test func aFailedRequestFallsBackAndIsNotRetriedForTheSameText() async {
        let claude = failing()
        let rig = makeRig(claude: claude)
        await rig.focus(dutch, caret: 3)
        await rig.check()

        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: .unreachable))
        #expect(await rig.visible().map(\.word) == ["gisterren"])
        #expect(await claude.requests.count == 1)

        await rig.recheckAtCaret()
        #expect(await claude.requests.count == 1)

        await type(variant(1), in: rig)
        #expect(await claude.texts == [dutch, variant(1)])
    }

    @Test func repeatedFailuresSuspendClaudeOnTheInjectedClock() async {
        let claude = failing()
        var onDevice = claudeSettings()
        onDevice.modelChecks[.nl] = true
        let rig = makeRig(onDevice, claude: claude, engine: .correcting(["word": "wordt"]))
        await rig.focus(variant(0), caret: 3)
        await rig.check()
        await type(variant(1), in: rig)
        let failedAt = rig.clock.now.offset
        #expect(await claude.requests.count == 2)
        #expect(await status(rig) == ClaudeStatus(sending: false, trouble: .unreachable, suspended: true))

        await type(variant(2), in: rig, at: failedAt + .seconds(29))
        #expect(await claude.requests.count == 2)
        #expect(await rig.engine.texts == [variant(0), variant(1), variant(2)])
        await type(variant(3), in: rig, at: failedAt + .seconds(30))
        #expect(await claude.requests.count == 3)
        #expect(await status(rig).sending == false)

        await type(variant(4), in: rig, at: failedAt + .seconds(30 + 59))
        #expect(await claude.requests.count == 3)
        await type(variant(5), in: rig, at: failedAt + .seconds(30 + 60))
        #expect(await claude.requests.count == 4)
    }

    @Test func theSuspensionIsOnlyTheClaudeIsSuspendedFlag() async {
        let rig = makeRig(claude: failing())
        await rig.focus(variant(0), caret: 3)
        await rig.check()
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: .unreachable, suspended: false))

        await rig.focus(flew, caret: 3, in: PipelineRig.fieldB)
        await rig.check()
        #expect(await status(rig) == ClaudeStatus(sending: false, trouble: .unreachable, suspended: false))

        await rig.focus(variant(1), caret: 3)
        await rig.check()
        #expect(await status(rig) == ClaudeStatus(sending: false, trouble: .unreachable, suspended: true))

        await rig.focus(flew, caret: 3, in: PipelineRig.fieldB)
        await rig.check()
        #expect(await status(rig) == ClaudeStatus(sending: false, trouble: .unreachable, suspended: true))
    }

    @Test func aSuccessClearsTheTroubleAndTheSuspension() async {
        let claude = FakeEngine { request, index in
            index < 2 ? .failure(.failed) : .success(replacingWords(in: request.text, corrections))
        }
        let rig = makeRig(claude: claude)
        await rig.focus(variant(0), caret: 3)
        await rig.check()
        await type(variant(1), in: rig)
        let failedAt = rig.clock.now.offset
        #expect(await status(rig) == ClaudeStatus(sending: false, trouble: .unreachable, suspended: true))

        await type(variant(2), in: rig, at: failedAt + .seconds(30))
        #expect(await claude.requests.count == 3)
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: nil))
        #expect(await rig.modelIssues().map(\.word) == ["gisterren", "word"])
    }

    @Test func aTextThatFailedBeforeShowsItsOwnTroubleWhenItIsNotAskedAgain() async {
        let claude = FakeEngine { request, _ in
            request.text == dutch ? .failure(.failed) : .success(replacingWords(in: request.text, corrections))
        }
        var onDevice = claudeSettings()
        onDevice.modelChecks[.nl] = true
        let rig = makeRig(onDevice, claude: claude, engine: .correcting(["word": "wordt"]))
        await rig.focus(dutch, caret: 3)
        await rig.check()
        await type(variant(1), in: rig)
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: nil))

        await type(dutch, in: rig)
        #expect(await claude.texts == [dutch, variant(1)])
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: .unreachable))
        #expect(await rig.engine.texts == [dutch, dutch])
        #expect(await rig.modelIssues().map(\.engine) == [.thisMac])

        var refreshed = onDevice
        refreshed.launchAtLogin = false
        await rig.update(refreshed)
        await rig.pipeline.drain()
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: .unreachable))

        await type(variant(2), in: rig)
        #expect(await claude.requests.count == 3)
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: nil))
    }

    @Test func aRefusedTextsTroubleGoesWhenTheCaretLeavesItsText() async {
        let claude = FakeEngine { request, _ in
            request.text == dutch ? .failure(.failed) : .success(replacingWords(in: request.text, corrections))
        }
        let rig = makeRig(claude: claude)
        await rig.focus(dutch + "\n" + flew, caret: 3)
        await rig.check()
        await type(variant(1) + "\n" + flew, in: rig)
        await type(dutch + "\n" + flew, in: rig)
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: .unreachable))

        await rig.access.moveCaret(to: dutch.utf16.count + 1 + 3, in: PipelineRig.fieldA)
        await rig.recheckAtCaret()
        #expect(await claude.requests.count == 2)
        #expect(await status(rig).trouble == nil)

        await type(dutch + "\n" + flew, in: rig)
        await rig.access.moveCaret(to: 3, in: PipelineRig.fieldA)
        await rig.recheckAtCaret()
        #expect(await status(rig).trouble == .unreachable)
        await rig.focus(flew, caret: 3, in: PipelineRig.fieldB)
        await rig.check()
        #expect(await status(rig).trouble == nil)
    }

    @Test func aTimeoutIsAFailure() async {
        let claude = FakeEngine.correcting(corrections, gated: true)
        let rig = makeRig(claude: claude)
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)

        rig.clock.advance(by: CheckPipeline.claudeTimeout)
        await rig.pipeline.drain()
        #expect(await status(rig).trouble == .unreachable)
        #expect(await rig.visible().map(\.word) == ["gisterren"])
        await claude.open()
    }

    @Test(arguments: zip(
        [EngineFailure.unavailable(.claudeKeyRejected), .unavailable(.claudeRateLimited)],
        [ClaudeTrouble.keyRejected, .rateLimited]
    ))
    func aRejectedKeyAndARateLimitSaySo(_ failure: EngineFailure, _ trouble: ClaudeTrouble) async {
        let rig = makeRig(claude: failing(failure))
        await rig.focus(dutch, caret: 3)
        await rig.check()
        #expect(await status(rig).trouble == trouble)
        #expect(await rig.visible().map(\.word) == ["gisterren"])
    }

    @Test func aRefusalSuspendsNothing() async {
        let claude = failing(.refused)
        let rig = makeRig(claude: claude)
        await rig.focus(variant(0), caret: 3)
        await rig.check()
        await type(variant(1), in: rig)
        await type(variant(2), in: rig)
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: .declined))

        await type(variant(3), in: rig)
        #expect(await claude.requests.count == 4)
    }

    @Test func theFallbackIsWhatTheOnDeviceSwitchesSay() async {
        var apple = claudeSettings()
        apple.modelChecks[.nl] = true
        let withApple = makeRig(apple, claude: failing(), engine: .correcting(["word": "wordt"]))
        await withApple.focus(dutch, caret: 3)
        await withApple.check()
        #expect(await withApple.engine.texts == [dutch])
        let fallback = await withApple.modelIssues()
        #expect(fallback.map(\.word) == ["word"])
        #expect(fallback.map(\.engine) == [.thisMac])

        let shipped = makeRig(claude: failing(), engine: .correcting(["word": "wordt"]))
        await shipped.focus(dutch, caret: 3)
        await shipped.check()
        #expect(await shipped.engine.requests.isEmpty)
        #expect(await shipped.modelIssues().isEmpty)

        let inFrench = makeRig(claude: failing(), engine: .correcting(["serveur": "serveurs"]))
        await inFrench.focus(french, caret: 3)
        await inFrench.check()
        #expect(await status(inFrench).trouble == .unreachable)
        #expect(await inFrench.engine.requests.isEmpty)
        #expect(await inFrench.visible().isEmpty)
    }

    @Test func issuesShownStayWhenALaterRequestFails() async {
        let claude = FakeEngine { request, index in
            index == 0 ? .success(replacingWords(in: request.text, ["word": "wordt"])) : .failure(.failed)
        }
        let rig = makeRig(claude: claude)
        await rig.focus(dutch + "\n" + dutch2, caret: 3)
        await rig.check()
        #expect(await rig.modelIssues().map(\.word) == ["word"])

        await rig.access.moveCaret(to: dutch.utf16.count + 1 + 3, in: PipelineRig.fieldA)
        await rig.recheckAtCaret()
        #expect(await claude.texts == [dutch, dutch2])
        #expect(await status(rig).trouble == .unreachable)
        #expect(await rig.modelIssues().map(\.word) == ["word"])
    }

    @Test func aNewKeyLetsClaudeBeAskedAgain() async {
        let claude = FakeEngine { request, index in
            index < 2 ? .failure(.failed) : .success(replacingWords(in: request.text, corrections))
        }
        let rig = makeRig(claude: claude)
        await rig.focus(variant(0), caret: 3)
        await rig.check()
        await type(variant(1), in: rig)
        #expect(await status(rig) == ClaudeStatus(sending: false, trouble: .unreachable, suspended: true))

        await rig.recheckAtCaret()
        #expect(await claude.requests.count == 2)

        await rig.pipeline.resetClaude()
        await rig.pipeline.drain()
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: nil))

        await rig.recheckAtCaret()
        #expect(await claude.texts == [variant(0), variant(1), variant(1)])
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: nil))
    }

    @Test func eachRequestSentReportsItsOutcome() async {
        let answering = makeRig(claude: FakeEngine.correcting(corrections))
        await answering.focus(dutch, caret: 3)
        await answering.check()
        #expect(answering.claudeOutcomes.outcomes == [.answered])

        let claude = FakeEngine.correcting(corrections, gated: true)
        let timedOut = makeRig(claude: claude)
        await timedOut.focus(dutch, caret: 3)
        timedOut.pass()
        await claude.waitForRequests(1)
        timedOut.clock.advance(by: CheckPipeline.claudeTimeout)
        await timedOut.pipeline.drain()
        #expect(timedOut.claudeOutcomes.outcomes == [.failed(.unreachable)])
        await claude.open()

        let outcomes: [(EngineFailure, ClaudeOutcome)] = [
            (.unavailable(.claudeKeyRejected), .failed(.keyRejected)),
            (.unavailable(.claudeRateLimited), .failed(.rateLimited)),
            (.refused, .failed(.declined)),
            (.failed, .failed(.unreachable)),
        ]
        for (failure, outcome) in outcomes {
            let rig = makeRig(claude: failing(failure))
            await rig.focus(dutch, caret: 3)
            await rig.check()
            #expect(rig.claudeOutcomes.outcomes == [outcome])
        }
    }

    @Test func aNewerPauseReportsCancelledAndAKeylessRequestReportsNothing() async {
        let claude = FakeEngine.correcting(corrections, gated: true)
        let rig = makeRig(claude: claude)
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)
        await rig.access.set(dutch + " nu", caret: 3, in: PipelineRig.fieldA)
        await rig.pipeline.receive(.edited(PipelineRig.fieldA))
        rig.pass()
        await claude.waitForRequests(2)
        #expect(rig.claudeOutcomes.outcomes == [.cancelled])
        await claude.open()
        await rig.pipeline.drain()
        #expect(rig.claudeOutcomes.outcomes == [.cancelled, .answered])

        let keyless = makeRig(claude: failing(.unavailable(.claudeKeyMissing)))
        await keyless.focus(dutch, caret: 3)
        await keyless.check()
        #expect(await status(keyless).trouble == .keyRejected)
        #expect(keyless.claudeOutcomes.outcomes.isEmpty)
    }

    @Test func cancellationIsNotAFailure() async {
        let claude = FakeEngine.correcting(corrections, gated: true)
        let rig = makeRig(claude: claude)
        await rig.focus(dutch, caret: 3)
        rig.pass()
        await claude.waitForRequests(1)

        await rig.pipeline.setPaused(true)
        await rig.pipeline.drain()
        #expect(await status(rig) == ClaudeStatus(sending: false, trouble: nil))

        await claude.open()
        await rig.pipeline.setPaused(false)
        await rig.check()
        #expect(await claude.texts == [dutch, dutch])
        #expect(await status(rig) == ClaudeStatus(sending: true, trouble: nil))
    }

    @Test func aSettingsUpdateRefreshesTheStatus() async {
        let rig = makeRig(claude: FakeEngine.correcting(corrections))
        await rig.focus(dutch, caret: 3)
        await rig.check()
        #expect(await status(rig).sending)

        await rig.router.set(PipelineRig.engineRouter(claudeSettings(), key: false))
        await rig.pipeline.update(settings: claudeSettings())
        await rig.pipeline.drain()
        #expect(await status(rig).sending == false)
    }

    @Test func aFocusChangeRefreshesTheStatus() async {
        let rig = makeRig(claude: FakeEngine.correcting(corrections))
        await rig.focus(dutch, caret: 3)
        await rig.check()
        #expect(await status(rig).sending)

        await rig.pipeline.receive(.focused(nil))
        await rig.pipeline.drain()
        #expect(await status(rig).sending == false)
    }

    @Test func aFallbackKeepsTheClaudeIssuesStillShownForTheSameText() async throws {
        var onDevice = claudeSettings()
        onDevice.modelChecks[.nl] = true
        let claude = FakeEngine { request, index in
            index == 0 ? .success(replacingWords(in: request.text, corrections)) : .failure(.failed)
        }
        let rig = makeRig(onDevice, claude: claude, engine: .correcting(["gisterren": "gisteren"]))
        await rig.focus(dutch, caret: 3)
        await rig.check()
        #expect(await rig.modelIssues().map(\.word) == ["gisterren", "word"])

        let flagged = try #require(await rig.modelIssues().first)
        #expect(await rig.pipeline.neverFlag(flagged.id) == "gisterren")
        await rig.recheckAtCaret()

        #expect(await claude.texts == [dutch, dutch])
        #expect(await rig.engine.requests.isEmpty)
        let issues = await rig.modelIssues()
        #expect(issues.map(\.word) == ["word"])
        #expect(issues.map(\.engine) == [.claude])
    }

    @Test func aChangedParagraphGetsTheFallbacksIssues() async {
        var onDevice = claudeSettings()
        onDevice.modelChecks[.nl] = true
        let claude = FakeEngine { request, index in
            index == 0 ? .success(replacingWords(in: request.text, ["gisterren": "gisteren"])) : .failure(.failed)
        }
        let rig = makeRig(onDevice, claude: claude, engine: .correcting(["word": "wordt"]))
        await rig.focus(dutch, caret: 3)
        await rig.check()
        #expect(await rig.modelIssues().map(\.engine) == [.claude])

        await type(variant(1), in: rig)
        #expect(await rig.engine.texts == [variant(1)])
        let issues = await rig.modelIssues()
        #expect(issues.map(\.word) == ["word"])
        #expect(issues.map(\.engine) == [.thisMac])
    }
}
