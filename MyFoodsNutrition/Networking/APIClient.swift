import Foundation
import os

/// Unified logging (Xcode console / Console.app). Same module as `SyncEngine`.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "MyFoodsNutrition"
    static let api = Logger(subsystem: subsystem, category: "API")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
}

/// Talks to PHP API: `POST {base}/sync/push.php`, `GET {base}/sync/pull.php?since_id=`.
final class APIClient {
    var config: APIConfig
    private let session: URLSession

    /// Longer than `URLSession.shared` defaults to reduce spurious `nw_read_request_report … Operation timed out` on slow mobile networks / shared hosting.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 240
        config.timeoutIntervalForResource = 1_800
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Per-request cap (seconds). `URLRequest` otherwise defaults to 60s and can ignore session limits for idle reads.
    private static let requestTimeoutInterval: TimeInterval = 300

    private static let transportRetryCount = 2

    init(config: APIConfig, session: URLSession? = nil) {
        self.config = config
        self.session = session ?? Self.defaultSession
    }

    func push(operations: [DailyItemDTO.PushOperation]) async throws -> DailyItemDTO.PushResponse {
        guard config.isConfigured else { throw APIError.notConfigured }
        guard let url = URL(string: config.baseURL + "/sync/push.php") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeoutInterval
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let body = DailyItemDTO.PushRequest(operations: operations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)

        return try await perform(request, decode: DailyItemDTO.PushResponse.self)
    }

    func pull(sinceId: Int64) async throws -> DailyItemDTO.PullResponse {
        guard config.isConfigured else { throw APIError.notConfigured }
        var components = URLComponents(string: config.baseURL + "/sync/pull.php")
        components?.queryItems = [URLQueryItem(name: "since_id", value: String(sinceId))]
        guard let url = components?.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeoutInterval
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        return try await perform(request, decode: DailyItemDTO.PullResponse.self)
    }

    /// Same server logic as `findItemDB.php` (Bearer auth).
    func searchFoods(query: String) async throws -> FoodSearchResponse {
        guard config.isConfigured else { throw APIError.notConfigured }
        guard let url = URL(string: config.baseURL + "/search-items.php") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeoutInterval
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let body: [String: String] = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await perform(request, decode: FoodSearchResponse.self, label: "searchFoods")
    }

    /// Full `table_items_data` export for offline search and local day totals (`catalog-items.php`).
    func fetchFoodCatalog() async throws -> FoodCatalogResponse {
        guard config.isConfigured else { throw APIError.notConfigured }
        guard let url = URL(string: config.baseURL + "/catalog-items.php") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeoutInterval
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        return try await perform(request, decode: FoodCatalogResponse.self, label: "fetchFoodCatalog")
    }

    /// DRI goals, Hebrew labels, and `table_items_data` column order for offline nutrition tables (`nutrition-attributes.php`).
    func fetchNutritionAttributes() async throws -> NutritionSnapshotResponse {
        guard config.isConfigured else { throw APIError.notConfigured }
        guard let url = URL(string: config.baseURL + "/nutrition-attributes.php") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeoutInterval
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        return try await perform(request, decode: NutritionSnapshotResponse.self, label: "fetchNutritionAttributes")
    }

    private func perform<T: Decodable>(_ request: URLRequest, decode: T.Type, label: String) async throws -> T {
        let typeName = String(describing: T.self)
        let path = request.url?.path ?? "(no path)"
        AppLog.api.info("[\(label)] → \(request.httpMethod ?? "?") \(path) decode=\(typeName)")

        let attempts = 1 + Self.transportRetryCount
        for attempt in 1 ... attempts {
            do {
                return try await performOnce(request: request, decode: decode, typeName: typeName, label: label)
            } catch let APIError.transport(err) {
                let retry = attempt < attempts && Self.shouldRetryTransport(err)
                if retry {
                    let delayNs = UInt64(attempt) * 600_000_000
                    AppLog.api.info("[\(label)] transport failed (attempt \(attempt)/\(attempts)), retry after delay: \(String(describing: err))")
                    try await Task.sleep(nanoseconds: delayNs)
                    continue
                }
                AppLog.api.error("[\(label)] transport failed: \(String(describing: err))")
                throw APIError.transport(err)
            }
        }
        throw APIError.transport(URLError(.unknown))
    }

    private func performOnce<T: Decodable>(request: URLRequest, decode: T.Type, typeName: String, label: String) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            AppLog.api.error("[\(label)] not HTTP response")
            throw APIError.transport(URLError(.badServerResponse))
        }

        guard (200 ... 299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)
            let preview = (text ?? "").prefix(500)
            AppLog.api.error("[\(label)] HTTP \(http.statusCode) bodyPrefix=\(String(preview))")
            throw APIError.httpStatus(http.statusCode, text)
        }

        let decoder = JSONDecoder()
        do {
            let value = try decoder.decode(T.self, from: data)
            AppLog.api.info("[\(label)] decoded \(typeName) bytes=\(data.count)")
            return value
        } catch {
            let bodyPreview = String(data: data.prefix(1200), encoding: .utf8) ?? "<binary \(data.count) bytes>"
            AppLog.api.error("[\(label)] JSON decode FAILED type=\(typeName) error=\(Self.decodingErrorDetail(error)) bodyPrefix=\(bodyPreview)")
            throw APIError.decoding(error)
        }
    }

    /// Retries help with `nw_read_request_report … timed out` on flaky LTE / shared hosting when the server is slow to respond.
    private static func shouldRetryTransport(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == URLError.cancelled.rawValue {
            return false
        }
        guard let urlErr = error as? URLError else { return false }
        switch urlErr.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func decodingErrorDetail(_ error: Error) -> String {
        guard let e = error as? DecodingError else {
            return error.localizedDescription
        }
        switch e {
        case let .typeMismatch(type, ctx):
            return "typeMismatch(\(type)) at \(codingPathString(ctx.codingPath)): \(ctx.debugDescription)"
        case let .valueNotFound(type, ctx):
            return "valueNotFound(\(type)) at \(codingPathString(ctx.codingPath)): \(ctx.debugDescription)"
        case let .keyNotFound(key, ctx):
            return "keyNotFound(\(key.stringValue)) at \(codingPathString(ctx.codingPath)): \(ctx.debugDescription)"
        case let .dataCorrupted(ctx):
            return "dataCorrupted at \(codingPathString(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: e)
        }
    }

    private static func codingPathString(_ path: [CodingKey]) -> String {
        path.map(\.stringValue).joined(separator: ".")
    }
}

private extension APIClient {
    func perform<T: Decodable>(_ request: URLRequest, decode: T.Type) async throws -> T {
        try await perform(request, decode: T.self, label: pathLabel(request.url))
    }

    func pathLabel(_ url: URL?) -> String {
        guard let p = url?.path else { return "request" }
        if p.hasSuffix("push.php") { return "push" }
        if p.hasSuffix("pull.php") { return "pull" }
        if p.hasSuffix("search-items.php") { return "search" }
        if p.hasSuffix("nutrition-attributes.php") { return "fetchNutritionAttributes" }
        if p.hasSuffix("catalog-items.php") { return "fetchFoodCatalog" }
        return (p as NSString).lastPathComponent
    }
}
