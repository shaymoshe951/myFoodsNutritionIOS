import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case httpStatus(Int, String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "הגדר כתובת API ואסימון בהגדרות או Secrets.plist"
        case .invalidURL:
            return "כתובת לא חוקית"
        case let .httpStatus(code, body):
            if let body, !body.isEmpty { return "שרת (\(code)): \(body)" }
            return "שרת החזיר קוד \(code)"
        case .decoding(let e):
            return "פענוח תשובה נכשל: \(e.localizedDescription)"
        case .transport(let e):
            return e.localizedDescription
        }
    }
}
