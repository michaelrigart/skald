import AppKit
import SkaldPlatform27

@main
final class SkaldApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var probe: Probe?

    static func main() {
        let app = NSApplication.shared
        let delegate = SkaldApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("Skald started")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Skald")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Skald", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        if CommandLine.arguments.contains("--probe") {
            startProbe()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        probe?.stop()
    }

    private func startProbe() {
        let probe = Probe()
        self.probe = probe
        Task {
            await probe.run(for: .seconds(60 * 60))
            NSApp.terminate(nil)
        }
    }
}
