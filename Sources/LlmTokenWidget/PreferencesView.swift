import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: QuotaModel
    @State private var apiKeyField = ""
    @State private var statusText = ""

    var body: some View {
        Form {
            Text("Paste your Z.AI API key from z.ai (manage API keys). Stored in the login keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Claude Code / Max quota uses the same OAuth session as the `claude` CLI (~/.claude/.credentials.json or the Keychain item Claude Code uses). Optional: CLAUDE_CODE_OAUTH_TOKEN or CLAUDE_OAUTH_TOKEN in the environment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("On macOS 26 (Tahoe), if the menu bar item is missing, open System Settings and search for “Menu Bar” or “Control Center” and ensure this app is allowed to show in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("API key", text: $apiKeyField)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save") {
                    if apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        KeychainStore.delete()
                        statusText = "Cleared (env var still used if set)."
                    } else if KeychainStore.save(apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        statusText = "Saved to keychain."
                    } else {
                        statusText = "Could not save to keychain."
                    }
                    model.preferencesDidSave()
                }
                .keyboardShortcut(.defaultAction)

                Button("Clear keychain") {
                    apiKeyField = ""
                    KeychainStore.delete()
                    statusText = "Keychain entry removed."
                    model.preferencesDidSave()
                }
            }

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 180)
        .onAppear {
            apiKeyField = KeychainStore.load() ?? ""
        }
    }
}
