import AppKit
import ServiceManagement
import SkaldCore
import SkaldPlatform27
import Synchronization

/// Builds the app's parts once and keeps them in step: every settings save, thermal change and app activation
/// sets a fresh router on `liveRouter`, then hands the settings to the pipeline, in that order.
final class CompositionRoot {
    let model: SettingsModel
    let textAccess: SystemTextAccess
    let liveRouter: LiveRouter
    let pipeline: CheckPipeline
    let apple: AppleEngine
    let hotkeys = HotkeyCenter()
    /// One transport for every remote request.
    let transport = URLSessionTransport()

    private let keychain = KeychainStore.claudeKey
    private let switches: AppSwitches
    private let commands: AsyncStream<PipelineCommand>.Continuation
    private var statusItem: StatusItemController?
    private var onboarding: Onboarding?
    private var settingsWindow: SettingsWindowController?
    private var overlay: OverlayController?
    private var panel: PanelController?
    private var panelWindow: PanelWindow?
    private var panelHotkey: HotkeyToken?
    private var reviewHotkey: HotkeyToken?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pauseEnd: Task<Void, Never>?
    private var frontApp: NSRunningApplication?
    private var applied: Settings
    private var claudeStatus = ClaudeStatus.quiet
    private var statusTask: Task<Void, Never>?
    private var unreadableTask: Task<Void, Never>?
    /// Whether the frontmost app gave no focused element once its retries ran out, and what the focused field's app gives.
    private var unreadable = false
    private var fieldCapabilities: AccessCapabilities?

    private enum PipelineCommand: Sendable {
        case route(EngineRouter, Settings)
        case pause(Bool)
        case claudeKeyChanged
    }

    struct Conditions {
        let apple: UnavailableReason?
        let thermalPaused: Bool
        let claudeKeyPresent: Bool
    }

    init() {
        let keychain = KeychainStore.claudeKey
        let store = SettingsStore(directory: Self.settingsDirectory)
        let (loaded, readOnly) = Self.load(store)
        let model = SettingsModel(settings: loaded, store: store, keychain: keychain, readOnly: readOnly)
        self.model = model
        let settings = model.settings
        applied = settings
        let switches = AppSwitches(settings)
        self.switches = switches
        textAccess = SystemTextAccess(isAppEnabled: { switches.isEnabled($0) }, clock: ContinuousClock())
        apple = AppleEngine()
        let claudeLog = ClaudeTypingLog()
        let transport = transport
        liveRouter = LiveRouter(Self.router(settings, Self.conditions(claudeKeyPresent: model.claudeKeyStored)))
        pipeline = CheckPipeline(
            access: textAccess,
            apple: apple,
            claude: { model in ClaudeEngine(model: model, apiKey: { keychain.read() }, transport: transport, options: .typing) },
            onClaudeRequest: { claudeLog.record($0) },
            spelling: SpellingChecker(),
            detector: SystemLanguageDetector(),
            oracle: SystemWordOracle(),
            confirmer: AppleConfirmer(engine: apple),
            clock: ContinuousClock(),
            settings: settings,
            router: liveRouter
        )
        let (stream, continuation) = AsyncStream.makeStream(of: PipelineCommand.self)
        commands = continuation
        Task { [liveRouter, pipeline] in
            await pipeline.start()
            for await command in stream {
                switch command {
                case let .route(router, settings):
                    await liveRouter.set(router)
                    await pipeline.update(settings: settings)
                case let .pause(paused):
                    await pipeline.setPaused(paused)
                case .claudeKeyChanged:
                    await pipeline.resetClaude()
                }
            }
        }
        statusTask = Task { [weak self, pipeline] in
            for await status in pipeline.claudeStatus {
                guard let self else { return }
                claudeStatus = status
                refreshStatus()
            }
        }
    }

    func start() {
        model.onChange = { [weak self] in self?.settingsChanged($0) }
        model.onClaudeKeyChange = { [weak self] in self?.commands.yield(.claudeKeyChanged) }
        statusItem = StatusItemController(
            actions: .init(
                pause: { [model] in model.pause(for: $0) },
                resume: { [model] in model.resume() },
                setApp: { [model] in model.setApp($0, mode: $1) },
                grantAccess: { [weak self] in self?.showOnboarding() },
                openSettings: { [weak self] in self?.openSettings() }
            ),
            frontApp: { [weak self] in self?.frontAppEntry() }
        )
        frontApp = Self.otherApp(NSWorkspace.shared.frontmostApplication)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { root, note in
            if let app = Self.otherApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) { root.frontApp = app }
            root.applyRouting()
        }
        observe(NotificationCenter.default, ProcessInfo.thermalStateDidChangeNotification) { root, _ in
            root.applyRouting()
        }
        let overlay = OverlayController(
            pipeline: pipeline, access: textAccess, settings: model, clipboard: SystemClipboard(), clock: ContinuousClock(),
            registrar: hotkeys, announcer: VoiceOverAnnouncer()
        )
        overlay.onFieldCapabilities = { [weak self] in
            self?.fieldCapabilities = $0
            self?.refreshStatus()
        }
        overlay.start()
        self.overlay = overlay
        unreadableTask = Task { [weak self, textAccess] in
            for await app in textAccess.unreadableApp {
                guard let self else { return }
                unreadable = app != nil
                refreshStatus()
            }
        }
        let panelWindow = PanelWindow()
        let panel = PanelController(window: panelWindow, clipboard: SystemClipboard())
        panelWindow.attach(panel)
        panelWindow.onClose = { [weak panel] in panel?.close() }
        self.panelWindow = panelWindow
        self.panel = panel
        registerPanelHotkey()
        registerReviewHotkey()
        syncLoginItem(launchAtLogin: model.settings.launchAtLogin, changed: false)
        applyPause()
        applyRouting()
        if !AccessibilityPermission.isGranted { showOnboarding() }
        Log.app.notice("Skald started")
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        overlay?.stop()
        overlay = nil
        hotkeys.unregisterAll()
        panel?.close()
        pauseEnd?.cancel()
        statusTask?.cancel()
        unreadableTask?.cancel()
        commands.finish()
    }

    /// The router for the current settings and conditions, or for `conditions` already read.
    func makeRouter(_ conditions: Conditions? = nil) -> EngineRouter {
        Self.router(model.settings, conditions ?? currentConditions())
    }

    /// The panel's engines for the current settings. Remote engines are cheap values, so build them per use.
    func makeEngines() -> [EngineKind: any Engine] {
        let settings = model.settings
        let keychain = keychain
        return [
            .thisMac: apple,
            .macStudio: StudioEngine(endpoint: settings.studio, transport: transport),
            .claude: ClaudeEngine(model: settings.claudeModel, apiKey: { keychain.read() }, transport: transport, options: .panel),
        ]
    }

    func openSettings() {
        let window = settingsWindow ?? SettingsWindowController(model: model)
        settingsWindow = window
        window.show()
    }

    // MARK: Applying changes

    private func settingsChanged(_ settings: Settings) {
        let previous = applied
        applied = settings
        switches.set(settings)
        if settings.appOverrides != previous.appOverrides { textAccess.appSwitchesChanged() }
        if settings.launchAtLogin != previous.launchAtLogin { syncLoginItem(launchAtLogin: settings.launchAtLogin, changed: true) }
        if settings.pausedUntil != previous.pausedUntil { applyPause() }
        if settings.panelHotkey != previous.panelHotkey { registerPanelHotkey() }
        if settings.reviewHotkey != previous.reviewHotkey { registerReviewHotkey() }
        applyRouting()
    }

    private func applyRouting() {
        let conditions = currentConditions()
        model.appleUnavailable = conditions.apple
        model.thermalPaused = conditions.thermalPaused
        let router = makeRouter(conditions)
        commands.yield(.route(router, model.settings))
        refreshStatus(conditions, router)
    }

    /// Pauses the pipeline until `pausedUntil`, then clears it, which saves and resumes.
    private func applyPause() {
        pauseEnd?.cancel()
        pauseEnd = nil
        guard let until = model.settings.pausedUntil, until > .now else {
            commands.yield(.pause(false))
            if model.settings.pausedUntil != nil { model.resume() }
            return
        }
        overlay?.leaveReview()
        commands.yield(.pause(true))
        let remaining = Duration.seconds(until.timeIntervalSinceNow)
        pauseEnd = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: remaining) } catch { return }
            guard let self, self.model.settings.pausedUntil == until else { return }
            Log.app.notice("pause ended")
            self.model.resume()
        }
    }

    private func refreshStatus() {
        let conditions = currentConditions()
        refreshStatus(conditions, makeRouter(conditions))
    }

    private func refreshStatus(_ conditions: Conditions, _ router: EngineRouter) {
        let languages = router.claudeTypingLanguages
        let state = StatusState.resolve(
            trusted: AccessibilityPermission.isGranted, pausedUntil: model.settings.pausedUntil, now: .now,
            apple: conditions.apple, thermalPaused: conditions.thermalPaused,
            claude: claudeStatus, claudeLanguages: languages,
            fallbacks: languages.map { ClaudeFallback(language: $0, route: router.onDevice($0)) }
        )
        let note = FieldAccessNote.resolve(unreadable: unreadable, focused: fieldCapabilities != nil, capabilities: fieldCapabilities)
        statusItem?.show(state, sendingToClaude: claudeStatus.sending, note: note)
    }

    private func currentConditions() -> Conditions {
        Self.conditions(claudeKeyPresent: model.claudeKeyStored)
    }

    private static func conditions(claudeKeyPresent: Bool) -> Conditions {
        Conditions(
            apple: AppleAvailability.current(),
            thermalPaused: ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
            claudeKeyPresent: claudeKeyPresent
        )
    }

    private static func router(_ settings: Settings, _ conditions: Conditions) -> EngineRouter {
        EngineRouter(
            settings: settings, appleAvailability: conditions.apple,
            thermalPaused: conditions.thermalPaused, claudeKeyPresent: conditions.claudeKeyPresent
        )
    }

    // MARK: The panel

    private func registerPanelHotkey() {
        if let panelHotkey { hotkeys.unregister(panelHotkey) }
        let hotkey = model.settings.panelHotkey
        panelHotkey = hotkeys.register(hotkey) { [weak self] in self?.panelHotkeyPressed() }
        model.hotkeyNote = panelHotkey != nil ? nil : Self.refusal(of: hotkey)
    }

    private func registerReviewHotkey() {
        if let reviewHotkey { hotkeys.unregister(reviewHotkey) }
        let hotkey = model.settings.reviewHotkey
        reviewHotkey = hotkeys.register(hotkey) { [weak self] in self?.overlay?.toggleReview() }
        model.reviewHotkeyNote = reviewHotkey != nil ? nil : Self.refusal(of: hotkey)
    }

    private static func refusal(of hotkey: Hotkey) -> String {
        "macOS didn't accept \(hotkey.displayName); it may be reserved or taken by another app. Record another shortcut."
    }

    /// Captures the focused field before the panel shows: the selection, or the caret's paragraph. With no
    /// focused field, the panel works on the clipboard's text and offers only Copy. A press while Skald is
    /// active closes the panel; one during a Replace does nothing, so the Replace's outcome is still shown.
    private func panelHotkeyPressed() {
        guard let panel, !panel.isReplacing else { return }
        if panel.isOpen, NSApp.isActive { return panel.close() }
        let source = Self.otherApp(NSWorkspace.shared.frontmostApplication)
        let settings = model.settings
        let engines = makeEngines()
        let reserved = panel.reserveOpening()
        Task { [textAccess, liveRouter, pipeline, apple] in
            let focused = source == nil ? nil : await textAccess.focusedField()
            let captured = if let focused { await textAccess.capture(of: focused) } else { nil as SelectionCapture? }
            let content = PanelContent.resolve(focused: focused, capture: captured) { SystemClipboard.text() }
            let capture: SelectionCapture? = if case .field(let capture) = content { capture } else { nil }
            let text = switch content {
            case .field(let capture): capture.selectedText
            case .clipboard(let text): text
            case .unreadable: ""
            }
            let writes = if let capture { await textAccess.capabilities(for: capture.field.app).contains(.cleanWrite) } else { false }
            let fieldLanguage = if let focused { await pipeline.lastConfidentLanguage(for: focused) } else { nil as Language? }
            let app = source?.bundleIdentifier
            let router = await liveRouter.current
            let picker = router.pickerEngines(app: app)
            let session = PanelSession(
                capture: capture,
                text: text,
                detector: SystemLanguageDetector(),
                editGuard: EditGuard(neverTouch: Set(settings.neverTouch)),
                oracle: SystemWordOracle(),
                confirmer: AppleConfirmer(engine: apple),
                engines: engines,
                router: liveRouter,
                access: capture == nil ? nil : textAccess,
                app: app,
                fieldLanguage: fieldLanguage
            )
            let target = capture.map { capture in
                PanelOpening.Target(writes: writes) {
                    if let source {
                        NSApp.yieldActivation(to: source)
                        source.activate()
                    }
                    return await textAccess.waitForFocus(on: capture.field, timeout: .seconds(1))
                }
            }
            var opening = PanelOpening(session: session, text: text, target: target, engines: picker, engine: router.panelDefault(app: app))
            opening.needsLanguage = await session.needsLanguage()
            if content == .unreadable { opening.notice = PanelController.unreadableNotice }
            if case .clipboard = content { opening.fromClipboard = true }
            if let source, let app, settings.mode(app: app) == .thisMacOnly { opening.keptOnThisMac = source.localizedName ?? app }
            let opened = panel.open(opening, reserved: reserved)
            Log.ui.notice("panel opened: \(opened, privacy: .public), field \(capture != nil, privacy: .public), writes \(writes, privacy: .public)")
        }
    }

    // MARK: Accessibility

    private func showOnboarding() {
        let onboarding = self.onboarding ?? Onboarding { [weak self] in self?.trustGranted() }
        self.onboarding = onboarding
        onboarding.show()
    }

    private func trustGranted() {
        textAccess.observeFrontmostApp()
        applyRouting()
    }

    // MARK: Launch at login

    /// On launch, registers only when the switch is on and nothing is registered, so a choice made in
    /// System Settings stands; a change of the switch registers or unregisters.
    private func syncLoginItem(launchAtLogin: Bool, changed: Bool) {
        let service = SMAppService.mainApp
        do {
            switch LoginItemRule.action(enabled: launchAtLogin, status: LoginItemStatus(service.status), changed: changed) {
            case .register: try service.register()
            case .unregister: try service.unregister()
            case .none: break
            }
        } catch {
            Log.app.notice("login item not changed: \(String(describing: error), privacy: .private)")
        }
        model.loginItemNote = Self.loginItemNote(service.status, wanted: launchAtLogin)
    }

    private static func loginItemNote(_ status: SMAppService.Status, wanted: Bool) -> String? {
        switch (status, wanted) {
        case (.requiresApproval, true): "Allow Skald in System Settings → General → Login Items."
        case (.notRegistered, true), (.notFound, true): "Skald couldn't add itself to the login items."
        case (.enabled, false): "Skald is still in the login items."
        default: nil
        }
    }

    // MARK: Helpers

    private func frontAppEntry() -> StatusItemController.FrontApp? {
        guard let app = frontApp, !app.isTerminated, let bundleID = app.bundleIdentifier else { return nil }
        return .init(bundleID: bundleID, name: app.localizedName ?? bundleID, mode: model.settings.mode(app: bundleID), claudeTyping: model.settings.claudeTyping)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor (CompositionRoot, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let note = note // reason: delivered on the main queue and read only there
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self, note)
            }
        }
        observers.append((center, token))
    }

    private static func otherApp(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    private static var settingsDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent(SkaldCore.bundleID, isDirectory: true)
    }

    private static func load(_ store: SettingsStore) -> (Settings, readOnly: Bool) {
        switch store.load() {
        case .loaded(let settings):
            return (settings, false)
        case .fresh(let settings):
            Log.app.notice("settings: fresh")
            return (settings, false)
        case .recoveredFromCorrupt(let settings):
            Log.app.notice("settings: recovered from a corrupt file")
            return (settings, false)
        case .futureVersion(let version):
            Log.app.notice("settings: version \(version) is newer, read-only")
            return (Settings(), true)
        }
    }
}

/// The app switches text access asks about from its own queue.
nonisolated final class AppSwitches: Sendable {
    private let settings: Mutex<Settings>

    init(_ settings: Settings) {
        self.settings = Mutex(settings)
    }

    func set(_ new: Settings) {
        settings.withLock { $0 = new }
    }

    func isEnabled(_ app: String) -> Bool {
        settings.withLock { $0.isEnabled(app: app) }
    }
}

private extension LoginItemStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notRegistered
        }
    }
}
