import Foundation

struct QuotaClient {
    enum ClientError: LocalizedError {
        case missingKey
        case http(Int)
        case decode
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "No API key. Open Preferences and paste your Z.AI API key."
            case .http(let c): return "Server returned HTTP \(c)."
            case .decode: return "Could not read usage response."
            case .network(let e): return e.localizedDescription
            }
        }
    }

    private static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    /// Tries Bearer token first (matches subscription UI / OpenUsage); falls back to raw token.
    func fetchQuota(apiKey: String) async throws -> QuotaSummary {
        try await fetchQuotaWithAuth(apiKey: apiKey, bearer: true)
    }

    private func fetchQuotaWithAuth(apiKey: String, bearer: Bool) async throws -> QuotaSummary {
        let url = Self.quotaURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        }

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

        if http.statusCode == 401 || http.statusCode == 403, bearer {
            return try await fetchQuotaWithAuth(apiKey: apiKey, bearer: false)
        }

        guard (200 ... 299).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode)
        }

        let decoded = try? JSONDecoder().decode(QuotaEnvelope.self, from: data)
        guard decoded?.success == true, let limits = decoded?.data.limits else {
            throw ClientError.decode
        }

        let tokenLimits = limits.filter { $0.type == "TOKENS_LIMIT" }
        let session = tokenLimits.first { $0.unit == 3 && $0.number == 5 }
        let weekly = tokenLimits.first { $0.unit == 6 && $0.number == 7 }

        return QuotaSummary(
            session: session.map(TokenWindow.init(limit:)),
            weekly: weekly.map(TokenWindow.init(limit:))
        )
    }
}

struct QuotaEnvelope: Decodable {
    let code: Int?
    let success: Bool?
    let data: QuotaData
}

struct QuotaData: Decodable {
    let limits: [LimitEntry]
}

struct LimitEntry: Decodable {
    let type: String
    let unit: Int?
    let number: Int?
    let usage: Int64?
    let currentValue: Int64?
    let remaining: Int64?
    let percentage: Int?
    let nextResetTime: Int64?
}

struct TokenWindow {
    let usageTotal: Int64
    let consumed: Int64
    let remaining: Int64
    let usedPercent: Int
    let remainingPercent: Int
    let nextResetMs: Int64?

    init(limit: LimitEntry) {
        usageTotal = limit.usage ?? 0
        consumed = limit.currentValue ?? 0
        remaining = limit.remaining ?? max(0, usageTotal - consumed)
        let p = limit.percentage ?? 0
        usedPercent = min(100, max(0, p))
        remainingPercent = max(0, 100 - usedPercent)
        nextResetMs = limit.nextResetTime
    }
}

struct QuotaSummary {
    let session: TokenWindow?
    let weekly: TokenWindow?

    /// Prefer weekly for the menu bar (matches “subscription” feel); fall back to 5h session.
    var primary: TokenWindow? {
        weekly ?? session
    }
}
