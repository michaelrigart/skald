import CoreGraphics
import Foundation
import Testing
@testable import SkaldPlatform27

private let a = CGRect(x: 10, y: 100, width: 30, height: 14), b = a.offsetBy(dx: 0, dy: -40)

@Test func theLagRunsFromTheLastScrollToTheLastChange() {
    var trace = ScrollLagTrace()
    trace.scrolled(.trackpad, at: .milliseconds(0))
    trace.sampled(a, at: .milliseconds(10))
    trace.scrolled(.momentum, at: .milliseconds(100))
    trace.sampled(a, at: .milliseconds(110))
    trace.sampled(b, at: .milliseconds(180))
    trace.sampled(b, at: .milliseconds(190))
    #expect(trace.kind == .momentum)
    #expect(trace.lag == .milliseconds(80))
    #expect(!trace.isSettled(at: .milliseconds(1179)))
    #expect(trace.isSettled(at: .milliseconds(1180)))
}

@Test func boundsThatNeverChangeAfterTheLastScrollLagZero() {
    var trace = ScrollLagTrace()
    trace.sampled(a, at: .milliseconds(0))
    trace.scrolled(.wheel, at: .milliseconds(50))
    trace.sampled(a, at: .milliseconds(60))
    #expect(trace.lag == .zero)
}

@Test func aTraceStillChangingFiveSecondsAfterTheLastScrollGivesUp() {
    var trace = ScrollLagTrace()
    trace.scrolled(.wheel, at: .zero)
    #expect(!trace.gaveUp(at: .milliseconds(4999)))
    #expect(trace.gaveUp(at: .seconds(5)))
    #expect(ScrollLagTrace().lag == nil)
}

@Test func aGestureWithoutBoundsHasNoLagAndALateCatchUpIsUnsettled() {
    var blind = ScrollLagTrace()
    blind.scrolled(.wheel, at: .zero)
    blind.sampled(nil, at: .milliseconds(10))
    #expect(blind.lag == nil)
    var late = ScrollLagTrace()
    late.scrolled(.wheel, at: .zero)
    late.sampled(a, at: .milliseconds(10))
    #expect(!late.isUnsettled)
    late.checkedFinally(b)
    #expect(late.isUnsettled)
}

@Test func theCeilingIsTheLargestLagRoundedUpAndNeedsTwentySettledGestures() {
    let twenty: [Duration?] = Array(repeating: .milliseconds(40), count: 19) + [.milliseconds(101)]
    #expect(ScrollLagSummary.ceiling(twenty) == .milliseconds(150))
    #expect(ScrollLagSummary.ceiling(Array(repeating: .zero, count: 20)) == .milliseconds(50))
    #expect(ScrollLagSummary.ceiling(Array(twenty.dropLast())) == nil)
    #expect(ScrollLagSummary.ceiling(Array(twenty.dropLast()) + [nil]) == nil)
    #expect(ScrollLagSummary.ceiling(byKind: [.wheel: twenty, .trackpad: twenty, .momentum: Array(repeating: .milliseconds(200), count: 20)]) == .milliseconds(200))
    #expect(ScrollLagSummary.ceiling(byKind: [.wheel: twenty, .trackpad: twenty]) == nil)
}

@Test func theReportHoldsLagsPerAppAndKindAndTheAppsCeiling() throws {
    let twenty: [Duration?] = Array(repeating: .milliseconds(40), count: 19) + [.milliseconds(101)]
    let report = ScrollLagSummary.json(byApp: [
        "com.example.full": [.wheel: twenty, .trackpad: twenty, .momentum: twenty],
        "com.example.partial": [.wheel: [.milliseconds(30), nil]],
    ])
    let root = try #require(JSONSerialization.jsonObject(with: report) as? [String: Any])
    let full = try #require(root["com.example.full"] as? [String: Any])
    #expect(full["ceilingMs"] as? Int == 150)
    let wheel = try #require((full["lagsMs"] as? [String: [Any]])?["wheel"])
    #expect(wheel.count == 20)
    let partial = try #require(root["com.example.partial"] as? [String: Any])
    #expect(partial["ceilingMs"] is NSNull)
    let lags = try #require((partial["lagsMs"] as? [String: [Any]])?["wheel"])
    #expect(lags.count == 2)
    #expect(lags[0] as? Int == 30)
    #expect(lags[1] is NSNull)
}
