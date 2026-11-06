import AppKit

/// The one way the overlay and the panel put text on the clipboard, and only when the user presses Copy.
protocol Clipboard {
    func write(_ text: String)
}

/// The general pasteboard, written as an ordinary copy the user asked for.
final class SystemClipboard: Clipboard {
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    /// The clipboard's text for the panel when no field was captured, or nil when there is none or another
    /// app marked it concealed or transient, as password managers do.
    static func text() -> String? {
        let pasteboard = NSPasteboard.general
        guard !(pasteboard.types ?? []).contains(where: privateTypes.contains) else { return nil }
        return pasteboard.string(forType: .string)
    }

    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
