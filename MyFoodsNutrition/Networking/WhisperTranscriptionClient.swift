import Foundation

/// Multipart upload to `/api/transcribe-whisper-audio` (OpenAI Whisper on the server), same as `personal_assistant_app` `ApiClient.transcribeWithWhisperAudio`.
struct WhisperTranscriptionClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct Result: Sendable {
        let text: String
        let language: String?
    }

    func transcribeAudioFile(
        at fileURL: URL,
        autoDetectLanguage: Bool = false,
        language: String? = "he",
        baseURL: String = SpeechFallbackConfig.whisperBaseURL()
    ) async throws -> Result {
        let path = baseURL + "/api/transcribe-whisper-audio"
        var endpoint: URL
        if !autoDetectLanguage, let language, !language.isEmpty {
            var components = URLComponents(string: path)
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "language", value: language))
            components?.queryItems = items
            guard let u = components?.url else {
                throw WhisperError.invalidURL
            }
            endpoint = u
        } else {
            guard let u = URL(string: path) else {
                throw WhisperError.invalidURL
            }
            endpoint = u
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent.isEmpty ? "audio.wav" : fileURL.lastPathComponent

        var body = Data()
        // When fixed language is used, omit `autoDetectLanguage` entirely. Sending the string "false" is still
        // truthy in JavaScript `if (req.body.autoDetectLanguage)`, which can leave auto-detect on and ignore `language`.
        if autoDetectLanguage {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"autoDetectLanguage\"\r\n\r\n".data(using: .utf8)!)
            body.append("1\r\n".data(using: .utf8)!)
        }
        if !autoDetectLanguage, let language, !language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.badResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw WhisperError.http(http.statusCode, preview)
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let success = obj?["success"] as? Bool, success else {
            let err = (obj?["error"] as? String) ?? "unknown"
            throw WhisperError.serverError(err)
        }
        guard let text = obj?["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WhisperError.emptyTranscript
        }
        let lang = obj?["language"] as? String
        return Result(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: lang)
    }
}

enum WhisperError: LocalizedError {
    case invalidURL
    case badResponse
    case http(Int, String)
    case serverError(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "כתובת שרת תמלול לא תקינה."
        case .badResponse:
            return "תגובת שרת לא צפויה."
        case let .http(code, preview):
            return "תמלול מרחוק נכשל (\(code)): \(preview)"
        case let .serverError(msg):
            return "תמלול מרחוק: \(msg)"
        case .emptyTranscript:
            return "לא התקבל טקסט מהתמלול המרוחק."
        }
    }
}
