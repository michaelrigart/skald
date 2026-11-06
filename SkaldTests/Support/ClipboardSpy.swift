@testable import Skald

/// Records every clipboard write, in order, and writes nothing anywhere.
final class ClipboardSpy: Clipboard {
    private(set) var writes: [String] = []

    func write(_ text: String) {
        writes.append(text)
    }
}
