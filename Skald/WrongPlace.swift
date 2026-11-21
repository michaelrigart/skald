import AppKit

/// What a copy of Skald outside `/Applications` shows instead of checking anything: a status item with the
/// instruction and Quit, and the same instruction once as an alert. It reads and writes no text, asks for no
/// Accessibility access and registers no hotkey or login item.
final class WrongPlace {
    static let message = "Move Skald to the Applications folder, then open it again."

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init() {
        item.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: Self.message)
        item.button?.toolTip = Self.message
        let menu = NSMenu()
        let heading = NSMenuItem(title: Self.message, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Skald", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    func showAlert() {
        let alert = NSAlert()
        alert.messageText = "Skald isn't in the Applications folder"
        alert.informativeText = Self.message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
