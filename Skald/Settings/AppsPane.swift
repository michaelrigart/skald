import AppKit
import SkaldCore
import SwiftUI
import UniformTypeIdentifiers

/// Every app with a shipped default or a choice of its own, plus the apps running now. Skald itself is left out:
/// it never checks its own windows.
struct AppsPane: View {
    let model: SettingsModel

    private struct AppEntry: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skald checks what you type in the apps turned on here. Terminals, code editors and password managers start off.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(entries) { app in
                Toggle(isOn: Binding(
                    get: { model.settings.isEnabled(app: app.id) },
                    set: { model.setApp(app.id, enabled: $0) }
                )) {
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(app.name)
                    }
                }
                .toggleStyle(.switch)
            }
            HStack {
                Spacer()
                Button("Turn Off for Another App…", action: chooseApp)
            }
        }
    }

    private var entries: [AppEntry] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        let ids = Set(running).union(SettingsModel.shippedOffApps).union(model.settings.appOverrides.keys)
            .subtracting([SkaldCore.bundleID])
        return ids.compactMap { id -> AppEntry? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                return model.settings.appOverrides[id] == nil ? nil : AppEntry(id: id, name: id, icon: nil)
            }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return AppEntry(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "Turn Off"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        model.setApp(id, enabled: false)
    }
}
