import Foundation

/// Talks to PHP API: `POST {base}/sync/push.php`, `GET {base}/sync/pull.php?since_id=`.
final class APIClient {
    var config: APIConfig
    private let session: URLSession

    init(config: APIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func push(operations: [DailyItemDTO.PushOperation]) async throws -> DailyItemDTO.PushResponse {
        guard config.isConfigured else { throw APIError.notConfigured }
        guard let url = URL(string: config.baseURL + "/sync/push.php") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
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
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        return try await perform(request, decode: DailyItemDTO.PullResponse.self)
    }

    /// Same server logic as `findItemDB.php` (Bearer auth).
    func searchFoods(query: String) async throws -> FoodSearchResponse {
        guard config.isConfigured else { throw APIError.notConfigured }
        guard let url = URL(string: config.baseURL + "/search-items.php") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let body: [String: String] = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await perform(request, decode: FoodSearchResponse.self, label: "searchFoods")
    }

    private func perform<T: Decodable>(_ request: URLRequest, decode: T.Type, label: String) async throws -> T {
        let typeName = String(describing: T.self)
        let path = request.url?.path ?? "(no path)"
        AppLog.api.info("[\(label)] → \(request.httpMethod ?? "?") \(path) decode=\(typeName)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.api.error("[\(label)] transport failed: \(String(describing: error))")
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
        return (p as NSString).lastPathComponent
    }
}
