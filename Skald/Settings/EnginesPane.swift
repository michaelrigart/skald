import SkaldCore
import SwiftUI

struct EnginesPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Panel's default engine", selection: model.binding(\.panelDefaultEngine)) {
                    ForEach(EngineKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Checking while typing always runs on this Mac. Claude is used only when you pick it in the panel or make it the default here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("This Mac") {
                if let reason = model.appleUnavailable {
                    Text("Unavailable: \(reason.explanation).")
                } else {
                    Text("Apple's on-device model is available.")
                }
            }
            StudioSection(model: model)
            ClaudeSection(model: model)
        }
        .formStyle(.grouped)
    }
}

private struct StudioSection: View {
    let model: SettingsModel
    @State private var draft = StudioEndpoint()
    @State private var seeded = false

    /// The draft as it would be saved: the address and model without surrounding whitespace.
    private var endpoint: StudioEndpoint {
        StudioEndpoint(
            api: draft.api,
            baseURL: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var isCleared: Bool { endpoint.baseURL.isEmpty && endpoint.model.isEmpty }
    private var canSave: Bool { (endpoint.isConfigured || isCleared) && endpoint != model.settings.studio }

    var body: some View {
        Section("Mac Studio") {
            Picker("API", selection: $draft.api) {
                Text("Ollama").tag(StudioEndpoint.API.ollama)
                Text("OpenAI-compatible").tag(StudioEndpoint.API.openAICompatible)
            }
            TextField("Base URL", text: $draft.baseURL, prompt: Text("http://studio.local:11434"))
            TextField("Model", text: $draft.model)
            HStack {
                if !endpoint.isConfigured, !isCleared {
                    Text("Enter an http or https address with a host, and a model.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if !model.settings.studio.isConfigured {
                    Text("Without an address, the Mac Studio stays out of the panel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") { model.update { [endpoint] in $0.studio = endpoint } }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            draft = model.settings.studio
        }
    }
}

private struct ClaudeSection: View {
    let model: SettingsModel
    @State private var key = ""
    @State private var modelName = ""
    @State private var modelSeeded = false
    @State private var keyFailed = false

    var body: some View {
        Section("Claude") {
            LabeledContent("API key") {
                Text(model.claudeKeyStored ? "Stored in the Keychain" : "None")
                    .foregroundStyle(.secondary)
            }
            HStack {
                SecureField(model.claudeKeyStored ? "Replace the key" : "Paste a key", text: $key)
                    .onSubmit(saveKey)
                Button("Save Key", action: saveKey)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.claudeKeyStored {
                    Button("Remove") { keyFailed = !model.removeClaudeKey() }
                }
            }
            if keyFailed {
                Text("Skald couldn't change the key in the Keychain.").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                TextField("Model", text: $modelName)
                    .onSubmit(saveModel)
                Button("Save", action: saveModel)
                    .disabled(trimmedModel.isEmpty || trimmedModel == model.settings.claudeModel)
            }
        }
        .onAppear {
            guard !modelSeeded else { return }
            modelSeeded = true
            modelName = model.settings.claudeModel
        }
    }

    private var trimmedModel: String { modelName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keyFailed = !model.saveClaudeKey(key)
        key = ""
    }

    private func saveModel() {
        guard !trimmedModel.isEmpty else { return }
        model.update { $0.claudeModel = trimmedModel }
    }
}

extension EngineKind {
    var displayName: String {
        switch self {
        case .thisMac: "This Mac"
        case .macStudio: "Mac Studio"
        case .claude: "Claude"
        }
    }
}
