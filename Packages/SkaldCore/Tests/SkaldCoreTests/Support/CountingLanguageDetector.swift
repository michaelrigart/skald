import Foundation
@testable import SkaldCore

/// Counts the calls that reach the wrapped detector.
final class CountingLanguageDetector: LanguageDetecting, @unchecked Sendable { // reason: the count is only touched under the lock
    private let inner: any LanguageDetecting
    private let lock = NSLock()
    private var calls = 0

    init(_ inner: any LanguageDetecting = FakeLanguageDetector()) {
        self.inner = inner
    }

    var count: Int {
        lock.withLock { calls }
    }

    func detect(_ text: String, previous: Language?) -> Language? {
        lock.withLock { calls += 1 }
        return inner.detect(text, previous: previous)
    }
}
