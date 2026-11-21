import AppKit
import SkaldCore

/// Where a language's checks go while Claude can't answer.
struct ClaudeFallback: Equatable {
    let language: Language
    let route: TypingRoute
}

/// What the status item shows, most urgent first.
enum StatusState: Equatable {
    case onThisMac
    case usingClaude([Language], lastFailure: ClaudeTrouble?)
    case claudeTrouble(ClaudeTrouble, fallbacks: [ClaudeFallback])
    case paused(until: Date)
    case spellingOnly(UnavailableReason)
    case noAccessibility

    /// `claudeLanguages` are the languages the router would send to Claude, and `fallbacks` where each goes without it.
    static func resolve(
        trusted: Bool, pausedUntil: Date?, now: Date, apple: UnavailableReason?, thermalPaused: Bool,
        claude: ClaudeStatus, claudeLanguages: [Language], fallbacks: [ClaudeFallback]
    ) -> StatusState {
        guard trusted else { return .noAccessibility }
        if let pausedUntil, pausedUntil > now { return .paused(until: pausedUntil) }
        if !claudeLanguages.isEmpty {
            if claude.sending { return .usingClaude(claudeLanguages, lastFailure: claude.trouble) }
            if claude.suspended, let trouble = claude.trouble { return .claudeTrouble(trouble, fallbacks: fallbacks) }
        }
        if let apple { return .spellingOnly(apple) }
        if thermalPaused { return .spellingOnly(.thermalPause) }
        return .onThisMac
    }

    func title(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch self {
        case .onThisMac:
            return "Checking on this Mac"
        case .usingClaude(let languages, _):
            let names = languages.map(\.displayName).joined(separator: " and ")
            return "\(names) checks use Claude"
        case .claudeTrouble(let trouble, let fallbacks):
            guard !fallbacks.isEmpty else { return trouble.problem }
            return trouble.problem + ": " + fallbacks.map(\.sentence).joined(separator: ", ")
        case .paused(let until):
            let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
            return "Paused until \(until.formatted(style))"
        case .spellingOnly(let reason):
            return "Spelling only: \(reason.explanation)"
        case .noAccessibility:
            return "Skald needs Accessibility access"
        }
    }

    /// A second menu line, while checks still go to Claude after a failure.
    var detail: String? {
        guard case .usingClaude(_, let trouble?) = self else { return nil }
        return "Last check failed: \(trouble.problem)"
    }

    /// The menu's top lines: the state, its failure line, and the note on where Skald can't work. While a request
    /// can leave, the Claude line stays first and the note follows it; paused or without Accessibility, no note.
    func menuLines(note: FieldAccessNote?) -> [String] {
        switch self {
        case .paused, .noAccessibility: [title()]
        case .usingClaude: [title(), detail, note?.line].compactMap { $0 }
        case .onThisMac, .claudeTrouble, .spellingOnly: [note?.line, title()].compactMap { $0 }
        }
    }

    static let glyphName = "SkaldMenuBar", cloudGlyphName = "SkaldMenuBarCloud"

    /// The app's menu bar glyph, with the cloud while checks go to Claude; a copy, so the state's title doesn't
    /// change the shared image.
    func image(sendingToClaude: Bool) -> NSImage? {
        let name = sendingToClaude ? Self.cloudGlyphName : Self.glyphName
        guard let glyph = NSImage(named: name)?.copy() as? NSImage else { return nil }
        glyph.isTemplate = true
        glyph.accessibilityDescription = title()
        return glyph
    }
}

/// Where Skald can't work in the focused app, for the status menu.
enum FieldAccessNote: Equatable {
    case cantRead, badgeOnly, cantShow

    var line: String {
        switch self {
        case .cantRead: "Skald can't read text in this app"
        case .badgeOnly: "Issues are listed at the badge here"
        case .cantShow: "Skald can't show issues in this app"
        }
    }

    /// `unreadable`: the frontmost app answered no focused element once the retries ran out.
    static func resolve(unreadable: Bool, focused: Bool, capabilities: AccessCapabilities?) -> FieldAccessNote? {
        if unreadable { return .cantRead }
        guard focused, let capabilities else { return nil }
        if capabilities.contains(.rangeBounds) { return nil }
        return capabilities.contains(.fieldFrame) ? .badgeOnly : .cantShow
    }
}

private extension ClaudeTrouble {
    var problem: String {
        switch self {
        case .unreachable: "Claude unreachable"
        case .keyRejected: "Claude has no valid API key"
        case .rateLimited: "Claude is limiting requests"
        case .declined: "Claude declined a paragraph"
        }
    }
}

private extension ClaudeFallback {
    var sentence: String {
        switch route {
        case .model: "\(language.displayName) is checked on this Mac"
        case .claude: "\(language.displayName) is checked by Claude"
        case .spellingOnly: "\(language.displayName) is spelling only"
        case .off: "\(language.displayName) isn't checked while typing"
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
        case .claudeKeyRejected: "Claude didn't accept the API key"
        case .claudeRateLimited: "Claude is limiting requests"
        case .keptOnThisMac: "this app is kept on this Mac"
        }
    }
}

/// The menu bar item: its tooltip and description follow the state, and its menu is rebuilt each time it opens.
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        let pause: (_ interval: TimeInterval) -> Void
        let resume: () -> Void
        let setApp: (_ bundleID: String, _ mode: AppMode) -> Void
        let grantAccess: () -> Void
        let openSettings: () -> Void
    }

    /// The app the menu's per-app item acts on: the last app other than Skald to be frontmost.
    struct FrontApp: Equatable {
        let bundleID: String
        let name: String
        let mode: AppMode
        /// Whether Claude checks while typing are switched on.
        let claudeTyping: Bool
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let actions: Actions
    private let frontApp: () -> FrontApp?
    private var state = StatusState.onThisMac
    private var note: FieldAccessNote?

    init(actions: Actions, frontApp: @escaping () -> FrontApp?) {
        self.actions = actions
        self.frontApp = frontApp
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        show(.onThisMac, sendingToClaude: false)
    }

    isolated deinit {
        NSStatusBar.system.removeStatusItem(item)
    }

    func show(_ state: StatusState, sendingToClaude: Bool, note: FieldAccessNote? = nil) {
        self.state = state
        self.note = note
        item.button?.image = state.image(sendingToClaude: sendingToClaude)
        item.button?.toolTip = state.title()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in state.menuLines(note: note) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if let app = frontApp(), app.mode != .off {
            let keep = entry("Keep \(app.name) on This Mac", #selector(toggleKeep(_:)))
            keep.representedObject = app.bundleID
            keep.state = app.mode == .thisMacOnly ? .on : .off
            menu.addItem(keep)
        }
        if case .paused = state {
            menu.addItem(entry("Resume", #selector(resume)))
        } else {
            menu.addItem(entry("Pause for 30 Minutes", #selector(pauseForHalfAnHour)))
            menu.addItem(entry("Pause for an Hour", #selector(pauseForAnHour)))
        }
        if let app = frontApp() {
            let turnOff = app.mode != .off
            let toggle = entry(turnOff ? "Turn Off for \(app.name)" : "Turn On for \(app.name)", #selector(toggleApp(_:)))
            toggle.representedObject = app
            toggle.tag = turnOff ? 0 : 1
            menu.addItem(toggle)
        }
        if state == .noAccessibility {
            menu.addItem(entry("Grant Accessibility Access…", #selector(grantAccess)))
        }
        menu.addItem(.separator())
        menu.addItem(legendEntry())
        menu.addItem(entry("Settings…", #selector(openSettings), key: ","))
        let quit = NSMenuItem(title: "Quit Skald", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    /// The underline colours as a submenu. Its items are enabled without an action, so the dots aren't dimmed.
    private func legendEntry() -> NSMenuItem {
        let submenu = NSMenu(title: "Underline Colours")
        submenu.autoenablesItems = false
        for category in IssueCategory.allCases {
            let item = NSMenuItem(title: category.title, action: nil, keyEquivalent: "")
            item.image = Self.dot(CategoryPalette.color(category))
            submenu.addItem(item)
        }
        let legend = NSMenuItem(title: "Underline Colours", action: nil, keyEquivalent: "")
        legend.submenu = submenu
        return legend
    }

    private static func dot(_ colour: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            colour.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    @objc private func pauseForHalfAnHour() { actions.pause(30 * 60) }
    @objc private func pauseForAnHour() { actions.pause(60 * 60) }
    @objc private func resume() { actions.resume() }
    @objc private func grantAccess() { actions.grantAccess() }
    @objc private func openSettings() { actions.openSettings() }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? FrontApp else { return }
        actions.setApp(app.bundleID, sender.tag == 1 ? Self.modeWhenTurnedOn(app.bundleID, claudeTyping: app.claudeTyping) : .off)
    }

    @objc private func toggleKeep(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        actions.setApp(bundleID, sender.state == .on ? .on : .thisMacOnly)
    }

    /// Turning an app on never makes it eligible for Claude by itself: an app that ships off (a terminal, a
    /// password manager), or any app while Claude checks while typing are on, comes on for This Mac only, and
    /// ticking "Keep on This Mac" off is the explicit choice.
    static func modeWhenTurnedOn(_ bundleID: String, claudeTyping: Bool) -> AppMode {
        Settings.defaultMode(app: bundleID) == .off || claudeTyping ? .thisMacOnly : .on
    }
}
