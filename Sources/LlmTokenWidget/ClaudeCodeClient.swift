import Darwin
import Foundation

/// Fetches Claude Code / Claude Max session quota via Anthropic’s OAuth usage endpoint (same data as `/usage` in the CLI).
/// Uses the same token as `claude` after you sign in: `~/.claude/.credentials.json`, the macOS Keychain entry
/// Claude Code uses (`Claude Code-credentials`, same service as ClaudeBar’s ClaudeCredentialLoader), or
/// `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_OAUTH_TOKEN`.
/// Community-documented endpoint — may change without notice.
enum ClaudeCodeClient {
    /// 5h (or 7-day fallback) session remaining % and optional reset time from the same `/api/oauth/usage` payload.
    struct SessionUsage: Equatable {
        let remainingPercent: Int
        let resetsAt: Date?
    }

    enum ClientError: LocalizedError {
        /// `path` is the absolute path we tried (helps debug wrong home dir from GUI apps).
        case noCredentialsFile(path: String, detail: String)
        case noAccessToken
        case http(Int)
        case decode
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .noCredentialsFile(let path, let detail):
                return "Could not use Claude credentials at \(path). \(detail)"
            case .noAccessToken: return "No OAuth access token in credentials file."
            case .http(let c): return "Claude usage HTTP \(c)."
            case .decode: return "Could not parse Claude usage response."
            case .network(let e): return e.localizedDescription
            }
        }
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Same service name as Claude Code / ClaudeBar (`security find-generic-password -s …`).
    private static let claudeCodeKeychainService = "Claude Code-credentials"

    static func fetchSessionUsage() async throws -> SessionUsage {
        let token = try loadOAuthToken()
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("LlmTokenWidget/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.http(-1)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode)
        }

        return try sessionUsageFromUsageJSON(data)
    }

    /// Parses `five_hour` / `seven_day` utilization and matching `resets_at`; tolerates Int or Double and minor shape drift.
    private static func sessionUsageFromUsageJSON(_ data: Data) throws -> SessionUsage {
        if let decoded = try? JSONDecoder().decode(OAuthUsageResponse.self, from: data) {
            if let w = decoded.fiveHour, let u = w.utilization {
                return makeSessionUsage(utilization: u, resetsAtString: w.resetsAt)
            }
            if let w = decoded.sevenDay, let u = w.utilization {
                return makeSessionUsage(utilization: u, resetsAtString: w.resetsAt)
            }
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.decode
        }
        func window(_ key: String) -> (util: Double?, resetsAt: String?) {
            guard let w = obj[key] as? [String: Any] else { return (nil, nil) }
            let u: Double?
            if let d = w["utilization"] as? Double {
                u = d
            } else if let i = w["utilization"] as? Int {
                u = Double(i)
            } else {
                u = nil
            }
            let r = w["resets_at"] as? String
            return (u, r)
        }
        let five = window("five_hour")
        if let util = five.util {
            return makeSessionUsage(utilization: util, resetsAtString: five.resetsAt)
        }
        let seven = window("seven_day")
        if let util = seven.util {
            return makeSessionUsage(utilization: util, resetsAtString: seven.resetsAt)
        }
        throw ClientError.decode
    }

    private static func makeSessionUsage(utilization: Double, resetsAtString: String?) -> SessionUsage {
        let remaining = 100.0 - utilization
        let pct = max(0, min(100, Int(remaining.rounded())))
        let at = resetsAtString.flatMap { parseResetsAt($0) }
        return SessionUsage(remainingPercent: pct, resetsAt: at)
    }

    private static func parseResetsAt(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    private static func loadOAuthToken() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let t = env["CLAUDE_OAUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        if let t = env["CLAUDE_CODE_OAUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        let candidates = credentialsJSONCandidateURLs()
        var tried: [String] = []
        var readCredentialsPayload = false
        for url in candidates {
            tried.append(url.path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            readCredentialsPayload = true
            if let token = extractAccessToken(from: data), !token.isEmpty {
                return token
            }
        }
        if let kcData = keychainCredentialsJSONData() {
            readCredentialsPayload = true
            if let token = extractAccessToken(from: kcData), !token.isEmpty {
                return token
            }
        }
        if readCredentialsPayload {
            throw ClientError.noAccessToken
        }
        let summary = tried.isEmpty ? "(no candidate paths)" : tried.joined(separator: " · ")
        throw ClientError.noCredentialsFile(
            path: summary,
            detail: "No OAuth session found. Tried ~/.claude/.credentials.json (several home roots), Keychain item “\(claudeCodeKeychainService)”, and env CLAUDE_CODE_OAUTH_TOKEN / CLAUDE_OAUTH_TOKEN. Sign in with `claude`."
        )
    }

    /// Reads the same Keychain JSON Claude Code stores (see ClaudeBar `ClaudeCredentialLoader.loadFromKeychain`).
    private static func keychainCredentialsJSONData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", claudeCodeKeychainService, "-w"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let raw = out.fileHandleForReading.readDataToEndOfFile()
            guard let s = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s.data(using: .utf8)
        } catch {
            return nil
        }
    }

    /// Multiple ways to resolve “home” — GUI apps may set `$HOME` to a container; **passwd** home is usually correct.
    private static func credentialsJSONCandidateURLs() -> [URL] {
        var bases: [URL] = []
        var seen = Set<String>()
        func appendBase(_ url: URL) {
            let p = url.path
            guard p.hasPrefix("/"), p.count > 1, !seen.contains(p) else { return }
            seen.insert(p)
            bases.append(url)
        }
        if let pw = getpwuid(getuid()) {
            appendBase(URL(fileURLWithPath: String(cString: pw.pointee.pw_dir), isDirectory: true))
        }
        appendBase(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        appendBase(FileManager.default.homeDirectoryForCurrentUser)
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/"), home.count > 1 {
            appendBase(URL(fileURLWithPath: home, isDirectory: true))
        }
        return bases.map { $0.appendingPathComponent(".claude/.credentials.json") }
    }

    /// Decodes `claudeAiOauth.accessToken` and tolerates minor JSON shape differences.
    private static func extractAccessToken(from data: Data) -> String? {
        if let file = try? JSONDecoder().decode(CredentialsFile.self, from: data),
           let t = file.claudeAiOauth?.accessToken, !t.isEmpty {
            return t
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = obj["claudeAiOauth"] as? [String: Any]
        if let t = oauth?["accessToken"] as? String ?? oauth?["access_token"] as? String, !t.isEmpty {
            return t
        }
        return nil
    }
}

private struct CredentialsFile: Decodable {
    let claudeAiOauth: OAuthBlob?
}

private struct OAuthBlob: Decodable {
    let accessToken: String?
}

private struct OAuthUsageResponse: Decodable {
    let fiveHour: WindowUsage?
    let sevenDay: WindowUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct WindowUsage: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let d = try? c.decodeIfPresent(Double.self, forKey: .utilization) {
            utilization = d
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .utilization) {
            utilization = Double(i)
        } else {
            utilization = nil
        }
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}
