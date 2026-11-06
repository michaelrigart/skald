import AppKit
import ApplicationServices
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
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pauseEnd: Task<Void, Never>?
    private var frontApp: NSRunningApplication?
    private var applied: Settings

    private enum PipelineCommand: Sendable {
        case route(EngineRouter, Settings)
        case pause(Bool)
    }

    struct Conditions {
        let apple: UnavailableReason?
        let thermalPaused: Bool
        let claudeKeyPresent: Bool
    }

    init() {
        let keychain = KeychainStore.claudeKey
        let store = SettingsStore(directory: Self.settingsDirectory)
        let (settings, readOnly) = Self.load(store)
        let model = SettingsModel(settings: settings, store: store, keychain: keychain, readOnly: readOnly)
        self.model = model
        applied = settings
        let switches = AppSwitches(settings)
        self.switches = switches
        textAccess = SystemTextAccess(isAppEnabled: { switches.isEnabled($0) }, clock: ContinuousClock())
        apple = AppleEngine()
        liveRouter = LiveRouter(Self.router(settings, Self.conditions(claudeKeyPresent: model.claudeKeyStored)))
        pipeline = CheckPipeline(
            access: textAccess,
            apple: apple,
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
                }
            }
        }
    }

    func start() {
        model.onChange = { [weak self] in self?.settingsChanged($0) }
        statusItem = StatusItemController(
            actions: .init(
                pauseForAnHour: { [model] in model.pauseForAnHour() },
                resume: { [model] in model.resume() },
                setApp: { [model] in model.setApp($0, enabled: $1) },
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
            pipeline: pipeline, access: textAccess, settings: model, clipboard: SystemClipboard(), clock: ContinuousClock()
        )
        overlay.start()
        self.overlay = overlay
        syncLoginItem(launchAtLogin: model.settings.launchAtLogin, changed: false)
        applyPause()
        applyRouting()
        if !AXIsProcessTrusted() { showOnboarding() }
        Log.app.notice("Skald started")
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        overlay?.stop()
        overlay = nil
        pauseEnd?.cancel()
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
            .claude: ClaudeEngine(model: settings.claudeModel, apiKey: { keychain.read() }, transport: transport),
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
        applyRouting()
    }

    private func applyRouting() {
        let conditions = currentConditions()
        model.appleUnavailable = conditions.apple
        model.thermalPaused = conditions.thermalPaused
        commands.yield(.route(makeRouter(conditions), model.settings))
        refreshStatus(conditions)
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
        commands.yield(.pause(true))
        let remaining = Duration.seconds(until.timeIntervalSinceNow)
        pauseEnd = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: remaining) } catch { return }
            guard let self, self.model.settings.pausedUntil == until else { return }
            Log.app.notice("pause ended")
            self.model.resume()
        }
    }

    private func refreshStatus(_ conditions: Conditions) {
        let state = StatusState.resolve(
            trusted: AXIsProcessTrusted(), pausedUntil: model.settings.pausedUntil, now: .now,
            apple: conditions.apple, thermalPaused: conditions.thermalPaused
        )
        statusItem?.show(state)
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
            if launchAtLogin, changed || service.status == .notRegistered {
                if service.status != .enabled { try service.register() }
            } else if !launchAtLogin, changed, service.status != .notRegistered {
                try service.unregister()
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
        return .init(bundleID: bundleID, name: app.localizedName ?? bundleID, enabled: model.settings.isEnabled(app: bundleID))
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
