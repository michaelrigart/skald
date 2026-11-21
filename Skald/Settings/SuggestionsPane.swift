import SkaldCore
import SwiftUI

struct SuggestionsPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Underlines") {
                LegendView()
            }
            Section("Review") {
                LabeledContent("Review shortcut") {
                    HotkeyRecorder(hotkey: model.binding(\.reviewHotkey))
                }
                if let note = model.reviewHotkeyNote {
                    Text(note).font(.callout).foregroundStyle(.red)
                }
                Text("Steps through the issues in the focused field: → or ⇥ next, ← previous, ↩ accept, ⌫ dismiss, esc to leave.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Hidden suggestions") {
                if model.settings.hiddenKinds.isEmpty {
                    Text("Nothing is hidden.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.settings.hiddenKinds, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(get: { true }, set: { if !$0 { model.show(kind) } }))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
