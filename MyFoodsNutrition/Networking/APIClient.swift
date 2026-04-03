import Foundation

/// Talks to PHP API: `POST {base}/sync/push`, `GET {base}/sync/pull?since_id=`.
final class APIClient {
    var config: APIConfig
    private let session: URLSession

    init(config: APIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func push(operations: [DailyItemDTO.PushOperation]) async throws -> DailyItemDTO.PushResponse {
        guard config.isConfigured else { throw APIError.notConfigured }
        guard let url = URL(string: config.baseURL + "/sync/push") else { throw APIError.invalidURL }

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
        var components = URLComponents(string: config.baseURL + "/sync/pull")
        components?.queryItems = [URLQueryItem(name: "since_id", value: String(sinceId))]
        guard let url = components?.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        return try await perform(request, decode: DailyItemDTO.PullResponse.self)
    }

    private func perform<T: Decodable>(_ request: URLRequest, decode: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }

        guard (200 ... 299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)
            throw APIError.httpStatus(http.statusCode, text)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
