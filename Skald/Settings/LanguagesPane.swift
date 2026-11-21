import SkaldCore
import SwiftUI

struct LanguagesPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            if let reason = model.spellingOnlyReason {
                Section {
                    Label("Model checks aren't running: \(reason.explanation). Skald checks spelling only.", systemImage: "exclamationmark.triangle")
                }
            }
            ClaudeTypingSection(model: model)
            ForEach(Language.allCases, id: \.self) { language in
                Section(language.displayName) {
                    Toggle("Check while typing on this Mac", isOn: model.typingChecks(language))
                    Toggle("Model checks on this Mac (grammar and spelling)", isOn: model.modelChecks(language))
                        .disabled(!model.typingChecks(language).wrappedValue)
                    if model.claudeTakes(language) {
                        Text("Claude checks \(language.displayName) while typing. These switches apply when \(language.displayName) is back on this Mac: in apps kept on This Mac only, and when Claude can't answer.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let why = language.shippedOffReason {
                        Text(why).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClaudeTypingSection: View {
    let model: SettingsModel

    private var isOn: Binding<Bool> {
        Binding(get: { model.claudeTypingIsOn }, set: { model.setClaudeTyping($0) })
    }

    var body: some View {
        Section("Claude while typing") {
            Toggle("Check Dutch and French with Claude while typing", isOn: isOn)
                .disabled(!model.claudeKeyStored)
            if !model.claudeKeyStored {
                Text("Store a Claude API key under Engines to turn this on.").font(.callout).foregroundStyle(.secondary)
            }
            Toggle(Language.nl.displayName, isOn: model.claudeLanguage(.nl))
                .disabled(!isOn.wrappedValue)
            Toggle(Language.fr.displayName, isOn: model.claudeLanguage(.fr))
                .disabled(!isOn.wrappedValue)
            Text("While you type Dutch or French, Skald sends the paragraph you are typing in, and nothing else, to Anthropic's Claude API with your key. English stays on this Mac, and so does every app kept on This Mac only. The menu bar icon shows a cloud while checks go to Claude.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

extension Language {
    var displayName: String {
        switch self {
        case .en: "English"
        case .nl: "Dutch"
        case .fr: "French"
        }
    }

    /// Why a check ships off, from the evaluation's held-out grading (Eval/README.md). Fixed text, not read at run time.
    var shippedOffReason: String? {
        switch self {
        case .en:
            nil
        case .nl:
            "Model checks ship off for Dutch: on the held-out evaluation set, the model's suggestions missed the precision bar. Spelling checks passed it, so checking while typing stays on, as spelling only."
        case .fr:
            "Model checks and checking while typing ship off for French: on the held-out evaluation set, both the model's suggestions and spelling checks missed the precision bar. The panel still works in French."
        }
    }
}
