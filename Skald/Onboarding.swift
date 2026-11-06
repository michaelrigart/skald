import AppKit
import ApplicationServices
import SwiftUI

/// The Accessibility explanation shown on a launch without the grant. While it is open it asks once a second
/// whether trust has arrived, then closes itself and reports it.
final class Onboarding: NSObject, NSWindowDelegate {
    private static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let onTrusted: () -> Void
    private var window: NSWindow?
    private var poll: Timer?

    init(onTrusted: @escaping () -> Void) {
        self.onTrusted = onTrusted
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    private func startPolling() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    private func check() {
        guard AXIsProcessTrusted() else { return }
        Log.app.notice("accessibility granted")
        stopPolling()
        window?.close()
        onTrusted()
    }

    /// The prompt lists Skald in the Accessibility pane, switched off, so the user only has to switch it on.
    private static func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt, a global var Swift 6 won't read without isolation.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(accessibilityPane)
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView { Self.requestAccess() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Skald"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

private struct OnboardingView: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skald needs Accessibility access")
                .font(.title2.bold())
            Text("Skald reads the text field you are typing in to check its spelling and grammar, and changes it only when you accept a fix. macOS lets an app do that only with Accessibility access.")
            Text("Click Open Accessibility Settings: macOS adds Skald to the Accessibility list in Privacy & Security, and you switch it on there.")
            Text("Your text stays on this Mac, unless you choose the Mac Studio or Claude in the panel.")
                .foregroundStyle(.secondary)
            HStack {
                Text("This window closes by itself once access is granted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Accessibility Settings", action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 480)
    }
}
