import SkaldCore
import Testing
@testable import Skald

/// A sleep the test ends by hand.
@MainActor private final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep(_: Duration) async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Ends every sleep, then lets the woken tasks run.
    func open() async {
        isOpen = true
        let sleepers = waiting
        waiting = []
        sleepers.forEach { $0.resume() }
        for _ in 0..<50 { await Task.yield() }
    }
}

/// A sleep the test ends one at a time, remembering how long each was asked for.
@MainActor private final class Steps {
    private(set) var asked: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        asked.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Ends the oldest sleep, then lets the woken task run.
    func step() async {
        for _ in 0..<50 { await Task.yield() }
        if !waiting.isEmpty { waiting.removeFirst().resume() }
        for _ in 0..<50 { await Task.yield() }
    }
}

/// The keys the system reports as physically down.
@MainActor private final class Physical {
    var down: Set<UInt16> = []
}

@MainActor final class ReviewKeysTests {
    private let sixKeyCodes: Set<UInt16> = [124, 48, 123, 36, 51, 53]
    private let registrar = FakeRegistrar()
    private let gate = Gate()
    private let steps = Steps()
    private let physical = Physical()
    private let keys: ReviewKeys
    private var pressed: [ReviewMode.Key] = []

    init() {
        keys = ReviewKeys(registrar: registrar, sleep: { [gate] in await gate.sleep($0) }, isDown: { [physical] in physical.down.contains($0) })
    }

    /// Keys whose sleeps `steps` ends by hand.
    private func steppedKeys() -> ReviewKeys {
        ReviewKeys(registrar: registrar, sleep: { [steps] in await steps.sleep($0) }, isDown: { [physical] in physical.down.contains($0) })
    }

    private func hold() -> Bool {
        keys.hold { [self] in pressed.append($0) }
    }

    @Test func holdingRegistersTheSixKeysAndReleasingFreesThem() {
        #expect(hold() && keys.isHolding)
        #expect(Set(registrar.held.map(\.keyCode)) == sixKeyCodes)
        #expect(registrar.held.count == 6)
        #expect(registrar.held.allSatisfy { $0.modifiers == 0 })
        keys.release()
        #expect(registrar.held.isEmpty && !keys.isHolding)
    }

    @Test func aKeyThatDoesNotRegisterHoldsNothing() {
        for refused: UInt16 in sixKeyCodes {
            let registrar = FakeRegistrar(refusing: [refused])
            let keys = ReviewKeys(registrar: registrar, sleep: { [gate] in await gate.sleep($0) }, isDown: { _ in false })
            #expect(!keys.hold { _ in } && !keys.isHolding)
            #expect(registrar.held.isEmpty)
        }
    }

    @Test func aPressReportsItsKey() {
        _ = hold()
        for code: UInt16 in [124, 48, 123, 36, 51, 53] {
            registrar.press(code)
            registrar.lift(code)
        }
        #expect(pressed == [.next, .next, .previous, .accept, .dismiss, .leave])
    }

    @Test func aKeyStillDownIsHeldUntilItIsReleased() {
        _ = hold()
        registrar.press(51)
        keys.release()
        #expect(registrar.held.map(\.keyCode) == [51] && !keys.isHolding)
        registrar.press(51)
        #expect(pressed == [.dismiss])
        registrar.lift(51)
        #expect(registrar.held.isEmpty)
    }

    @Test func aKeyNeverReportedUpIsFreedAfterTheLimit() async {
        _ = hold()
        registrar.press(36)
        keys.release()
        #expect(registrar.held.map(\.keyCode) == [36])
        await gate.open()
        #expect(registrar.held.isEmpty)
    }

    @Test func theLimitIsOneSecond() async {
        var slept: [Duration] = []
        let keys = ReviewKeys(registrar: registrar, sleep: { slept.append($0) }, isDown: { _ in false })
        _ = keys.hold { _ in }
        registrar.press(36)
        keys.release()
        await gate.open()
        #expect(slept == [.seconds(1)] && ReviewKeys.lingerLimit == .seconds(1))
    }

    @Test func releasingWithEveryKeyUpStartsNoWait() async {
        var slept = 0
        let keys = ReviewKeys(registrar: registrar, sleep: { _ in slept += 1 }, isDown: { _ in false })
        _ = keys.hold { _ in }
        registrar.press(36)
        registrar.lift(36)
        keys.release()
        await gate.open()
        #expect(slept == 0 && registrar.held.isEmpty)
    }

    @Test func holdingTwiceRegistersOnce() {
        #expect(hold())
        let tokens = registrar.held.map(\.token)
        var second: [ReviewMode.Key] = []
        #expect(keys.hold { second.append($0) })
        #expect(registrar.held.map(\.token) == tokens)
        registrar.press(36)
        #expect(pressed == [.accept] && second.isEmpty)
    }

    @Test func aKeyHeldDownIsReportedOnce() {
        _ = hold()
        registrar.press(36)
        registrar.press(36)
        #expect(pressed == [.accept])
        registrar.lift(36)
        registrar.press(36)
        #expect(pressed == [.accept, .accept])
    }

    @Test func aKeyStillDownStaysHeldThroughTheNextHold() {
        _ = hold()
        registrar.press(51)
        keys.release()
        #expect(hold())
        keys.release()
        #expect(registrar.held.map(\.keyCode) == [51])
        registrar.lift(51)
        #expect(registrar.held.isEmpty)
        #expect(pressed == [.dismiss])
    }

    @Test func releasingWithoutHoldingDoesNothing() {
        keys.release()
        #expect(registrar.held.isEmpty && !keys.isHolding)
    }

    @Test func aHoldFreesTheKeysLeftOverFromTheLastRelease() {
        _ = hold()
        registrar.press(36)
        keys.release()
        #expect(registrar.held.count == 1)
        #expect(hold())
        #expect(registrar.held.count == 6 && registrar.held.map(\.token).count == Set(registrar.held.map(\.token)).count)
        pressed = []
        registrar.lift(36)
        registrar.press(36)
        #expect(pressed == [.accept])
    }

    @Test func anEarlierReleasesLimitDoesNotFreeALaterHold() async {
        _ = hold()
        registrar.press(36)
        keys.release()
        _ = hold()
        await gate.open()
        #expect(registrar.held.count == 6 && keys.isHolding)
    }

    @Test func aLateReleaseEventAfterTheLimitIsHarmless() async {
        _ = hold()
        registrar.press(36)
        keys.release()
        await gate.open()
        registrar.lift(36)
        #expect(registrar.held.isEmpty)
    }

    @Test func aKeyPhysicallyDownPastTheLimitStaysHeldUntilItIsUp() async {
        let keys = steppedKeys()
        _ = keys.hold { _ in }
        registrar.press(51)
        physical.down = [51]
        keys.release()
        await steps.step()
        #expect(registrar.held.map(\.keyCode) == [51])
        for _ in 0..<3 {
            await steps.step()
            #expect(registrar.held.map(\.keyCode) == [51])
        }
        physical.down = []
        await steps.step()
        #expect(registrar.held.isEmpty)
        #expect(steps.asked.first == ReviewKeys.lingerLimit)
        #expect(steps.asked.dropFirst().allSatisfy { $0 == ReviewKeys.lingerCheck } && ReviewKeys.lingerCheck == .milliseconds(100))
    }

    @Test func aKeyPhysicallyDownThatCarbonNeverSawStaysHeld() async {
        let keys = steppedKeys()
        _ = keys.hold { _ in }
        physical.down = [51]
        keys.release()
        #expect(registrar.held.map(\.keyCode) == [51])
        await steps.step()
        await steps.step()
        #expect(registrar.held.map(\.keyCode) == [51])
        registrar.lift(51)
        #expect(registrar.held.isEmpty)
    }

    @Test func aCarbonReleaseFreesAKeyPhysicallyDownAtOnce() async {
        let keys = steppedKeys()
        _ = keys.hold { _ in }
        registrar.press(51)
        physical.down = [51]
        keys.release()
        await steps.step()
        registrar.lift(51)
        #expect(registrar.held.isEmpty)
    }

    @Test func aKeyPhysicallyDownCarriesIntoTheNextHold() {
        _ = hold()
        physical.down = [51]
        keys.release()
        #expect(hold())
        pressed = []
        registrar.press(51)
        #expect(pressed.isEmpty)
        registrar.lift(51)
        registrar.press(51)
        #expect(pressed == [.dismiss])
    }
}
