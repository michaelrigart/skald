import AppKit
import Testing
@testable import Skald

/// Each test writes a private named pasteboard, never the general one.
@MainActor struct SystemClipboardTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.michaelrigart.skald.tests.\(UUID().uuidString)"))

    private func hold(_ text: String, marker: String? = nil) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let marker { pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
    }

    @Test func plainTextIsRead() {
        hold("We flew to teh office")
        #expect(SystemClipboard.text(from: pasteboard) == "We flew to teh office")
        pasteboard.releaseGlobally()
    }

    @Test(arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"])
    func concealedOrTransientTextIsNeverRead(_ marker: String) {
        hold("a password", marker: marker)
        #expect(SystemClipboard.text(from: pasteboard) == nil)
        pasteboard.releaseGlobally()
    }

    @Test func anEmptyClipboardHasNoText() {
        pasteboard.clearContents()
        #expect(SystemClipboard.text(from: pasteboard) == nil)
        pasteboard.releaseGlobally()
    }
}
