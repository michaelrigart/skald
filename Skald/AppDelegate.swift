import AppKit
import SkaldCore
import SkaldPlatform27

/// A test host builds nothing, so unit tests never start text access or show onboarding. Every other launch
/// from anywhere but `/Applications` shows only the move notice. From `/Applications` a normal launch builds
/// the composition root, and in a Debug build `--probe` runs the feasibility probe instead.
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
        let probeRequested = CommandLine.arguments.contains("--probe")
        #else
        let probeRequested = false
        #endif
        switch LaunchMode.resolve(isTestHost: Self.isTestHost, probeRequested: probeRequested, bundlePath: Bundle.main.bundlePath) {
        case .testHost:
            Log.app.notice("Skald started as a test host")
        case .wrongPlace:
            Log.app.notice("Skald is outside /Applications and checks nothing")
            let wrongPlace = WrongPlace()
            self.wrongPlace = wrongPlace
            wrongPlace.showAlert()
        case .probe:
            #if DEBUG
            startProbe()
            #else
            startNormally()
            #endif
        case .normal:
            startNormally()
        }
    }

    private func startNormally() {
        NSApp.mainMenu = Self.editMenu()
        let root = CompositionRoot()
        self.root = root
        root.start()
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

enum LaunchMode: Equatable {
    case testHost, wrongPlace, probe, normal

    static func resolve(isTestHost: Bool, probeRequested: Bool, bundlePath: String) -> LaunchMode {
        if isTestHost { return .testHost }
        if !InstallLocation.isSupported(bundlePath: bundlePath) { return .wrongPlace }
        return probeRequested ? .probe : .normal
    }
}
