import AppKit
import SwiftUI

/// The Settings window, made once and shown again from the status menu.
final class SettingsWindowController {
    private let window: NSWindow

    init(model: SettingsModel) {
        window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Skald Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
    }

    func show() {
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            if let note = model.saveNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])
            }
            TabView {
                GeneralPane(model: model).tabItem { Label("General", systemImage: "gearshape") }
                AppsPane(model: model).tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                WordsPane(model: model).tabItem { Label("Words", systemImage: "text.book.closed") }
                LanguagesPane(model: model).tabItem { Label("Languages", systemImage: "globe") }
                EnginesPane(model: model).tabItem { Label("Engines", systemImage: "cpu") }
            }
            .padding()
        }
        .frame(width: 560, height: 460)
    }
}
