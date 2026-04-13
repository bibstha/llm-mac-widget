import AppKit
import SwiftUI

@main
struct LlmTokenWidgetApp: App {
    @StateObject private var model = QuotaModel()

    var body: some Scene {
        MenuBarExtra(content: {
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

            Divider()

            Toggle(isOn: Binding(
                get: { model.useOneMinuteAutoRefresh },
                set: { model.useOneMinuteAutoRefresh = $0 }
            )) {
                Text("Refresh every 1 minute")
            }
            .toggleStyle(.checkbox)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Token quota")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: .labelColor))

                ForEach(Array(model.quotaMenuLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .focusable(false)
        }, label: {
            MenuBarLabelView(model: model)
        })
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView(model: model)
        }
    }
}

private struct MenuBarLabelView: View {
    @ObservedObject var model: QuotaModel

    var body: some View {
        Text("\(model.autoRefreshRemainingSeconds) \(model.barTitle)")
            .font(.system(.caption, design: .default))
            .fontWeight(.semibold)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .help(model.barTooltip)
    }
}
