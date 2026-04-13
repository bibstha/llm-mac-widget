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

            // TimelineView for countdown avoids republishing the model every second (NSMenu highlight glitch).
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

                AutoRefreshCountdown(deadline: model.nextAutomaticRefreshAt)
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
        // One line so minimumScaleFactor shrinks everything together; split HStacks had one side clipped entirely.
        Text("\(model.menuBarCountdownSeconds) \(model.barTitle)")
            .font(.system(.caption, design: .default))
            .fontWeight(.semibold)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .help(model.barTooltip)
    }
}

private struct AutoRefreshCountdown: View {
    var deadline: Date

    var body: some View {
        // `context.date` can lag after the menu is closed/reopened; use wall-clock remaining time.
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            let totalSec = max(0, Int(deadline.timeIntervalSinceNow.rounded(.down)))
            let m = totalSec / 60
            let s = totalSec % 60
            Text("Auto refresh in \(m):\(String(format: "%02d", s)) (\(totalSec)s)")
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }
}
