import AppKit

/// The one way the overlay and the panel put text on the clipboard, and only when the user presses Copy.
protocol Clipboard {
    func write(_ text: String)
}

/// The general pasteboard, written as an ordinary copy the user asked for.
final class SystemClipboard: Clipboard {
    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
