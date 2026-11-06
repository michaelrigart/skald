import AppKit
import SkaldCore
import SkaldPlatform27

/// Builds the composition root on a normal launch from `/Applications`; from anywhere else it shows only the
/// move notice. In a Debug build the `--probe` launch runs the feasibility probe instead, and a test host
/// builds nothing, so unit tests never start text access or show onboarding.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var root: CompositionRoot?
    private var wrongPlace: WrongPlace?
    #if DEBUG
    private var probe: Probe?
    private var probeItem: NSStatusItem?
    #endif

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--probe") {
            startProbe()
            return
        }
        #endif
        if Self.isTestHost {
            Log.app.notice("Skald started as a test host")
        } else if !InstallLocation.isSupported(bundlePath: Bundle.main.bundlePath) {
            Log.app.notice("Skald is outside /Applications and checks nothing")
            let wrongPlace = WrongPlace()
            self.wrongPlace = wrongPlace
            wrongPlace.showAlert()
        } else {
            NSApp.mainMenu = Self.editMenu()
            let root = CompositionRoot()
            self.root = root
            root.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        probe?.stop()
        #endif
        root?.stop()
    }

    /// A menu bar app shows no main menu, but text fields find ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z through it.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Skald", action: nil, keyEquivalent: ""))
        main.addItem(item)
        return main
    }

    #if DEBUG
    private func startProbe() {
        Log.app.notice("Skald started in probe mode")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Skald")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Skald", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        probeItem = item
        let probe = Probe()
        self.probe = probe
        Task {
            await probe.run(for: .seconds(60 * 60))
            NSApp.terminate(nil)
        }
    }
    #endif
}
