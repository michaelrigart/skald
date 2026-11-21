import Foundation

public enum ClaudeTrouble: String, Equatable, Sendable {
    case unreachable, keyRejected, rateLimited, declined

    public init?(_ failure: EngineFailure) {
        switch failure {
        case .cancelled: return nil
        case .unavailable(.claudeKeyRejected), .unavailable(.claudeKeyMissing): self = .keyRejected
        case .unavailable(.claudeRateLimited): self = .rateLimited
        case .refused, .truncated: self = .declined
        case .timedOut, .failed, .unavailable: self = .unreachable
        }
    }
}

/// Pure, on the caller's clock (durations since the pipeline's origin).
public struct ClaudeBackoff: Sendable {
    public static let suspendAfter = 2
    public static let firstSuspension: Duration = .seconds(30)
    public static let longestSuspension: Duration = .seconds(300)
    public static let rememberedTexts = 32

    public private(set) var trouble: ClaudeTrouble?
    private var streak = 0
    private var suspendedUntil: Duration?
    private var failedHashes: [Int] = []

    public init() {}

    public func isSuspended(at now: Duration) -> Bool {
        guard let suspendedUntil else { return false }
        return now < suspendedUntil
    }

    public func mayAsk(about text: String, at now: Duration) -> Bool {
        !isSuspended(at: now) && !failedHashes.contains(text.hashValue)
    }

    public mutating func failed(_ trouble: ClaudeTrouble, text: String, at now: Duration) {
        failedHashes.append(text.hashValue)
        if failedHashes.count > Self.rememberedTexts {
            failedHashes.removeFirst(failedHashes.count - Self.rememberedTexts)
        }
        self.trouble = trouble
        guard trouble != .declined else { return }
        streak += 1
        guard streak >= Self.suspendAfter else { return }
        let steps = streak - Self.suspendAfter
        let interval = steps >= 4 ? Self.longestSuspension : Self.firstSuspension * (1 << steps)
        suspendedUntil = now + min(interval, Self.longestSuspension)
    }

    public mutating func succeeded() {
        streak = 0
        suspendedUntil = nil
        trouble = nil
    }
}
