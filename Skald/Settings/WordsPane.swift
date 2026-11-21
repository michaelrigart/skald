import SwiftUI

struct WordsPane: View {
    let model: SettingsModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skald never flags or changes these words: names, product terms, jargon.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                ForEach(model.settings.neverTouch, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            model.removeNeverTouch(word)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(word)")
                    }
                }
            }
            HStack {
                TextField("Add a word", text: $draft)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func add() {
        model.addNeverTouch(draft)
        draft = ""
    }
}
