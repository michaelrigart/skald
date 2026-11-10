import SwiftUI

struct AboutPane: View {
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Self.version)
            }
        }
        .formStyle(.grouped)
    }
}
