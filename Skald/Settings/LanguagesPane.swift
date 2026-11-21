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
            ForEach(Language.allCases, id: \.self) { language in
                Section(language.displayName) {
                    Toggle("Check while typing", isOn: model.typingChecks(language))
                    Toggle("Model checks (grammar and spelling)", isOn: model.modelChecks(language))
                        .disabled(!model.typingChecks(language).wrappedValue)
                    if let why = language.shippedOffReason {
                        Text(why).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
