import AppKit
import SwiftUI

@main
struct LlmTokenWidgetApp: App {
    @StateObject private var model = QuotaModel()

    var body: some Scene {
        MenuBarExtra(content: {
            Section {
                Text(model.autoRefreshLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 320, alignment: .leading)

                ForEach(Array(model.quotaMenuLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            } header: {
                Text("Token quota")
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            Divider()

            Button("Refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            SettingsLink {
                Text("Preferences…")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Z.AI Tokens") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }, label: {
            Text(model.barTitle)
                .font(.system(.caption, design: .default))
                .fontWeight(.semibold)
                .help(model.barTooltip)
        })
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView(model: model)
        }
    }
}
