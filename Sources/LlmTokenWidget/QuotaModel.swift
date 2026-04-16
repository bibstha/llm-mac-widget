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
    /// Seconds until next automatic quota refresh; updated every 5s for the menu bar (not every second).
    @Published private(set) var autoRefreshRemainingSeconds: Int = 0
    @Published private(set) var barTooltip: String = "Z.AI + Claude Code quota"
    /// Lines shown at the top of the menu (numbers / windows).
    @Published private(set) var quotaMenuLines: [String] = ["Open Preferences to set your API key."]

    private let client = QuotaClient()
    private var cancellables = Set<AnyCancellable>()
    private var autoRefreshTask: Task<Void, Never>?
    private var nextAutoRefreshAt: Date

    private var isRefreshing = false
    /// Last good Claude Code % from the OAuth usage API; used when the API returns HTTP 429 (heavy rate limits on `/api/oauth/usage`).
    private var lastSuccessfulCCPercent: Int?
    /// Same fetch as `lastSuccessfulCCPercent` — used to show a live “Resets in …” line when the latest request fails.
    private var lastSuccessfulCCResetAt: Date?

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

        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateAutoRefreshRemainingSeconds()
            }
            .store(in: &cancellables)

        updateAutoRefreshRemainingSeconds()
        Task { await refresh() }
    }

    private func updateAutoRefreshRemainingSeconds() {
        let sec = max(0, Int(nextAutoRefreshAt.timeIntervalSinceNow.rounded(.down)))
        if sec != autoRefreshRemainingSeconds {
            autoRefreshRemainingSeconds = sec
        }
    }

    private func scheduleNextAutoRefresh() {
        nextAutoRefreshAt = Date().addingTimeInterval(autoRefreshIntervalSeconds)
        updateAutoRefreshRemainingSeconds()
        autoRefreshTask?.cancel()
        let deadline = nextAutoRefreshAt
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(0, deadline.timeIntervalSinceNow)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
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
                [zaiQuotaMenuLine(percent: primary.remainingPercent, nextResetMs: primary.nextResetMs)]
                    + zaiSupplementaryMenuLines(from: summary)
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
            let usage = try await ClaudeCodeClient.fetchSessionUsage()
            lastSuccessfulCCPercent = usage.remainingPercent
            lastSuccessfulCCResetAt = usage.resetsAt
            let resetTooltip = usage.resetsAt.map { "Next window reset: \(formatResetClock($0))." } ?? ""
            let tooltipBody =
                "Claude Code: \(usage.remainingPercent)% remaining in current 5h session (OAuth)."
                    + (resetTooltip.isEmpty ? "" : " \(resetTooltip)")
            let lines = [claudeQuotaMenuLine(percent: usage.remainingPercent, resetsAt: usage.resetsAt, isStale: false)]
            return (
                "CC\(usage.remainingPercent)",
                tooltipBody,
                lines
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
                // Usage API is rate-limited and flaky; keep showing the last good % instead of a useless CC!.
                if let last = lastSuccessfulCCPercent {
                    let lines = [claudeQuotaMenuLine(percent: last, resetsAt: lastSuccessfulCCResetAt, isStale: true)]
                    let resetHint = lastSuccessfulCCResetAt.map { " Last known reset: \(formatResetClock($0))." } ?? ""
                    return (
                        "CC\(last)",
                        "Claude Code: \(last)% (last successful fetch). Could not refresh: \(e.localizedDescription).\(resetHint)",
                        lines
                    )
                }
                return (
                    "CC!",
                    "Claude Code: \(e.localizedDescription)",
                    ["Claude Code — \(e.localizedDescription)"]
                )
            }
        } catch {
            if let last = lastSuccessfulCCPercent {
                let lines = [claudeQuotaMenuLine(percent: last, resetsAt: lastSuccessfulCCResetAt, isStale: true)]
                let resetHint = lastSuccessfulCCResetAt.map { " Last known reset: \(formatResetClock($0))." } ?? ""
                return (
                    "CC\(last)",
                    "Claude Code: \(last)% (last successful fetch). Could not refresh: \(error.localizedDescription).\(resetHint)",
                    lines
                )
            }
            return (
                "CC!",
                "Claude Code: \(error.localizedDescription)",
                ["Claude Code — \(error.localizedDescription)"]
            )
        }
    }

    /// Extra token-cap lines when both weekly and 5-hour limits exist (the compact line already reflects `primary` = weekly).
    private func zaiSupplementaryMenuLines(from summary: QuotaSummary) -> [String] {
        guard summary.weekly != nil, let session = summary.session else { return [] }
        return [
            "5-hour: \(session.remainingPercent)% left · \(formatTokens(session.remaining)) tokens remaining "
                + "(used \(session.usedPercent)% of \(formatTokens(session.usageTotal)) cap)"
        ]
    }

    /// Matches Claude: `Z 78% remaining, Resets in 4:20` using `nextResetTime` from the quota API.
    private func zaiQuotaMenuLine(percent: Int, nextResetMs: Int64?) -> String {
        var s = "Z \(percent)% remaining"
        if let ms = nextResetMs {
            let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            s += ", Resets in \(formatResetHoursMinutes(to: date))"
        }
        return s
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

    /// Same clock style as Z.AI reset hints, for Claude OAuth `resets_at`.
    private func formatResetClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Single menu line: `Claude 78% remaining, Resets in 4:20` (or `(stale)` when the last fetch failed).
    private func claudeQuotaMenuLine(percent: Int, resetsAt: Date?, isStale: Bool) -> String {
        var s = "Claude \(percent)% remaining"
        if let r = resetsAt {
            s += ", Resets in \(formatResetHoursMinutes(to: r))"
        }
        if isStale {
            s += " (stale)"
        }
        return s
    }

    /// Countdown until OAuth window reset, `H:MM` (minutes zero-padded).
    private func formatResetHoursMinutes(to reset: Date) -> String {
        let seconds = max(0, Int(reset.timeIntervalSinceNow.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
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
