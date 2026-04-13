import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class QuotaModel: ObservableObject {
    private static let fastRefreshDefaultsKey = "LlmTokenWidget.useOneMinuteAutoRefresh"

    /// When `true`, automatic quota refresh runs every 1 minute; when `false`, every 5 minutes (default).
    @Published var useOneMinuteAutoRefresh: Bool = UserDefaults.standard.object(forKey: fastRefreshDefaultsKey) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(useOneMinuteAutoRefresh, forKey: Self.fastRefreshDefaultsKey)
            if oldValue != useOneMinuteAutoRefresh {
                scheduleNextAutoRefresh()
            }
        }
    }

    private var autoRefreshIntervalSeconds: TimeInterval {
        useOneMinuteAutoRefresh ? 60 : 300
    }

    /// Menu bar label, e.g. "Z85 CC86" (compact, no : or %).
    @Published private(set) var barTitle: String = "Z CC"
    /// Seconds until next automatic refresh (e.g. 300, 299…), updated every second for the menu bar.
    @Published private(set) var menuBarCountdownSeconds: Int = 0
    @Published private(set) var barTooltip: String = "Z.AI + Claude Code quota"
    /// Lines shown at the top of the menu (numbers / windows).
    @Published private(set) var quotaMenuLines: [String] = ["Open Preferences to set your API key."]

    private let client = QuotaClient()
    private var cancellables = Set<AnyCancellable>()
    private var nextAutoRefreshAt: Date

    /// Next automatic quota fetch time (menu countdown reads this; it does not update every second).
    var nextAutomaticRefreshAt: Date { nextAutoRefreshAt }
    private var isRefreshing = false

    init() {
        let interval: TimeInterval = UserDefaults.standard.object(forKey: Self.fastRefreshDefaultsKey) as? Bool == true ? 60 : 300
        nextAutoRefreshAt = Date().addingTimeInterval(interval)

        NSApp.setActivationPolicy(.accessory)

        if isatty(STDIN_FILENO) != 0 {
            let cwd = FileManager.default.currentDirectoryPath
            fputs(
                "\nLlmTokenWidget: started from Terminal — do not Ctrl+C if you want the menu item to stay. "
                    + "Prefer: open \"\(cwd)/LlmTokenWidget.app\"\n\n",
                stderr
            )
        }

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
            .store(in: &cancellables)

        updateMenuBarCountdownSeconds()
        Task { await refresh() }
    }

    private func tick() {
        updateMenuBarCountdownSeconds()
        guard !isRefreshing, Date() >= nextAutoRefreshAt else { return }
        Task { await refresh() }
    }

    private func updateMenuBarCountdownSeconds() {
        menuBarCountdownSeconds = max(0, Int(nextAutoRefreshAt.timeIntervalSinceNow.rounded(.down)))
    }

    private func scheduleNextAutoRefresh() {
        nextAutoRefreshAt = Date().addingTimeInterval(autoRefreshIntervalSeconds)
        updateMenuBarCountdownSeconds()
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            scheduleNextAutoRefresh()
        }

        barTitle = "Z… CC…"
        barTooltip = "Loading…"
        quotaMenuLines = ["Loading quota…"]

        async let zBlock = fetchZBlock()
        async let ccBlock = fetchCCBlock()
        let (z, cc) = await (zBlock, ccBlock)

        barTitle = "\(z.barFragment) \(cc.barFragment)"
        barTooltip = [z.tooltip, cc.tooltip].filter { !$0.isEmpty }.joined(separator: "\n\n")
        quotaMenuLines = z.menuLines + cc.menuLines
    }

    /// Z.AI quota (GLM API key).
    private func fetchZBlock() async -> (barFragment: String, tooltip: String, menuLines: [String]) {
        guard let key = resolvedAPIKey(), !key.isEmpty else {
            return (
                "Z—",
                "Z.AI: set API key in Preferences (or ZAI_API_KEY / GLM_API_KEY).",
                ["Z.AI — no API key"]
            )
        }
        do {
            let summary = try await client.fetchQuota(apiKey: key)
            guard let primary = summary.primary else {
                return (
                    "Z?",
                    "Z.AI: no TOKENS_LIMIT in response.",
                    ["Z.AI — no quota block in API response"]
                )
            }
            return (
                "Z\(primary.remainingPercent)",
                tooltip(for: summary),
                ["Z.AI"] + menuLines(from: summary)
            )
        } catch {
            return (
                "Z!",
                "Z.AI: \(error.localizedDescription)",
                ["Z.AI — \(error.localizedDescription)"]
            )
        }
    }

    /// Claude Code / Max — OAuth session (same credentials as `claude` CLI after console sign-in).
    private func fetchCCBlock() async -> (barFragment: String, tooltip: String, menuLines: [String]) {
        do {
            let pct = try await ClaudeCodeClient.fetchSessionRemainingPercent()
            return (
                "CC\(pct)",
                "Claude Code: \(pct)% remaining in current 5h session (OAuth).",
                ["Claude Code / Max — 5h session: \(pct)% remaining"]
            )
        } catch let e as ClaudeCodeClient.ClientError {
            switch e {
            case .noCredentialsFile, .noAccessToken:
                return (
                    "CC—",
                    "Claude Code: \(e.localizedDescription)",
                    ["Claude Code — \(e.localizedDescription)"]
                )
            case .http, .decode, .network:
                return (
                    "CC!",
                    "Claude Code: \(e.localizedDescription)",
                    ["Claude Code — \(e.localizedDescription)"]
                )
            }
        } catch {
            return (
                "CC:!",
                "Claude Code: \(error.localizedDescription)",
                ["Claude Code — \(error.localizedDescription)"]
            )
        }
    }

    private func menuLines(from summary: QuotaSummary) -> [String] {
        var lines: [String] = []
        if let w = summary.weekly {
            lines.append(
                "7-day: \(w.remainingPercent)% left · \(formatTokens(w.remaining)) tokens remaining "
                    + "(used \(w.usedPercent)% of \(formatTokens(w.usageTotal)) cap)"
            )
        }
        if let s = summary.session {
            lines.append(
                "5-hour: \(s.remainingPercent)% left · \(formatTokens(s.remaining)) tokens remaining "
                    + "(used \(s.usedPercent)% of \(formatTokens(s.usageTotal)) cap)"
            )
        }
        if lines.isEmpty {
            lines.append("No token windows returned.")
        }
        return lines
    }

    func preferencesDidSave() {
        Task { await refresh() }
    }

    private func tooltip(for summary: QuotaSummary) -> String {
        var lines: [String] = []
        if let s = summary.session {
            lines.append(sessionLine(label: "5h window", window: s))
        }
        if let w = summary.weekly {
            lines.append(sessionLine(label: "7-day window", window: w))
        }
        return lines.joined(separator: "\n")
    }

    private func sessionLine(label: String, window: TokenWindow) -> String {
        let rem = formatTokens(window.remaining)
        let next = formatReset(window.nextResetMs)
        return "\(label): \(window.remainingPercent)% tokens left (~\(rem) remaining)\(next)"
    }

    private func formatReset(_ ms: Int64?) -> String {
        guard let ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return " · next reset \(f.string(from: date))"
    }

    private func formatTokens(_ n: Int64) -> String {
        let d = Double(n)
        if n >= 1_000_000_000 {
            return String(format: "%.2fB", d / 1_000_000_000)
        }
        if n >= 1_000_000 {
            return String(format: "%.1fM", d / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fK", d / 1_000)
        }
        return "\(n)"
    }

    private func resolvedAPIKey() -> String? {
        if let k = KeychainStore.load(), !k.isEmpty { return k }
        if let env = ProcessInfo.processInfo.environment["ZAI_API_KEY"], !env.isEmpty { return env }
        if let env = ProcessInfo.processInfo.environment["GLM_API_KEY"], !env.isEmpty { return env }
        return nil
    }
}
