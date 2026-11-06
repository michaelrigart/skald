import AppKit
import SkaldCore

/// What the status item shows, most urgent first.
enum StatusState: Equatable {
    case on
    case paused(until: Date)
    case spellingOnly(UnavailableReason)
    case noAccessibility

    static func resolve(trusted: Bool, pausedUntil: Date?, now: Date, apple: UnavailableReason?, thermalPaused: Bool) -> StatusState {
        guard trusted else { return .noAccessibility }
        if let pausedUntil, pausedUntil > now { return .paused(until: pausedUntil) }
        if let apple { return .spellingOnly(apple) }
        if thermalPaused { return .spellingOnly(.thermalPause) }
        return .on
    }

    func title(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch self {
        case .on:
            return "Skald is on"
        case .paused(let until):
            let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
            return "Paused until \(until.formatted(style))"
        case .spellingOnly(let reason):
            return "Spelling only: \(reason.explanation)"
        case .noAccessibility:
            return "Skald needs Accessibility access"
        }
    }

    var symbolName: String {
        switch self {
        case .on: "text.badge.checkmark"
        case .paused: "pause.circle"
        case .spellingOnly: "textformat.abc"
        case .noAccessibility: "exclamationmark.triangle"
        }
    }
}

extension UnavailableReason {
    /// Fixed text for the status item and Settings.
    var explanation: String {
        switch self {
        case .appleIntelligenceOff: "Apple Intelligence is off"
        case .deviceNotEligible: "this Mac can't run Apple Intelligence"
        case .modelNotReady: "Apple's model isn't ready yet"
        case .thermalPause: "paused while this Mac is hot"
        case .languageOff: "model checks are off for this language"
        case .studioNotConfigured: "the Mac Studio has no address yet"
        case .studioUnreachable: "the Mac Studio can't be reached"
        case .claudeKeyMissing: "no Claude API key is stored"
        }
    }
}

/// The menu bar item: its symbol and tooltip follow the state, and its menu is rebuilt each time it opens.
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        let pauseForAnHour: () -> Void
        let resume: () -> Void
        let setApp: (_ bundleID: String, _ enabled: Bool) -> Void
        let grantAccess: () -> Void
        let openSettings: () -> Void
    }

    /// The app the menu's per-app item acts on: the last app other than Skald to be frontmost.
    struct FrontApp: Equatable {
        let bundleID: String
        let name: String
        let enabled: Bool
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let actions: Actions
    private let frontApp: () -> FrontApp?
    private var state = StatusState.on

    init(actions: Actions, frontApp: @escaping () -> FrontApp?) {
        self.actions = actions
        self.frontApp = frontApp
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        show(.on)
    }

    func show(_ state: StatusState) {
        self.state = state
        let title = state.title()
        item.button?.image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: title)
        item.button?.toolTip = title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: state.title(), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        if case .paused = state {
            menu.addItem(entry("Resume", #selector(resume)))
        } else {
            menu.addItem(entry("Pause for an Hour", #selector(pauseForAnHour)))
        }
        if let app = frontApp() {
            let toggle = entry(app.enabled ? "Turn Off for \(app.name)" : "Turn On for \(app.name)", #selector(toggleApp(_:)))
            toggle.representedObject = app.bundleID
            toggle.tag = app.enabled ? 0 : 1
            menu.addItem(toggle)
        }
        if state == .noAccessibility {
            menu.addItem(entry("Grant Accessibility Access…", #selector(grantAccess)))
        }
        menu.addItem(.separator())
        menu.addItem(entry("Settings…", #selector(openSettings), key: ","))
        let quit = NSMenuItem(title: "Quit Skald", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func pauseForAnHour() { actions.pauseForAnHour() }
    @objc private func resume() { actions.resume() }
    @objc private func grantAccess() { actions.grantAccess() }
    @objc private func openSettings() { actions.openSettings() }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        actions.setApp(bundleID, sender.tag == 1)
    }
}
