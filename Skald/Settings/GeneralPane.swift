import AppKit
import SkaldCore
import SwiftUI

struct GeneralPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch Skald at login", isOn: model.binding(\.launchAtLogin))
                if let note = model.loginItemNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Panel hotkey") {
                    HotkeyRecorder(hotkey: model.binding(\.panelHotkey))
                }
                if let note = model.hotkeyNote {
                    Text(note).font(.callout).foregroundStyle(.red)
                }
                Text("Opens the fix and rewrite panel on the selection, or on the paragraph at the caret.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                TimelineView(.everyMinute) { context in
                    if let until = model.settings.pausedUntil, until > context.date {
                        LabeledContent("Paused until \(until.formatted(date: .omitted, time: .shortened))") {
                            Button("Resume") { model.resume() }
                        }
                    } else {
                        LabeledContent("Checking is on") {
                            Button("Pause for an Hour") { model.pauseForAnHour() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shows the hotkey; Record takes the next key press with ⌘, ⌃ or ⌥ while this window is key. Escape cancels.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(monitor == nil ? hotkey.displayName : "Type a shortcut…")
                .monospaced()
                .foregroundStyle(monitor == nil ? .primary : .secondary)
            Button(monitor == nil ? "Record" : "Cancel") {
                monitor == nil ? start() : stop()
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
            } else if let recorded = Hotkey(event: event) {
                hotkey = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
