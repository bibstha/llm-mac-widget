import Darwin
import Foundation

/// Fetches Claude Code / Claude Max session quota via Anthropic’s OAuth usage endpoint (same data as `/usage` in the CLI).
/// Uses the same token as `claude` after you sign in: `~/.claude/.credentials.json`, the macOS Keychain entry
/// Claude Code uses (`Claude Code-credentials`, same service as ClaudeBar’s ClaudeCredentialLoader), or
/// `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_OAUTH_TOKEN`.
/// Community-documented endpoint — may change without notice.
enum ClaudeCodeClient {
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

    static func fetchSessionRemainingPercent() async throws -> Int {
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

        let decoded = try? JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        guard let util = decoded?.fiveHour?.utilization else {
            throw ClientError.decode
        }
        let remaining = 100.0 - util
        return max(0, min(100, Int(remaining.rounded())))
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

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
    }
}

private struct WindowUsage: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
