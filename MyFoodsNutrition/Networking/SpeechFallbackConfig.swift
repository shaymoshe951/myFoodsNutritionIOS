import Foundation

/// Base URL for the Whisper fallback API (same contract as `personal_assistant_app`: `POST /api/transcribe-whisper-audio`).
enum SpeechFallbackConfig {
    private static let userDefaultsKey = "whisper_fallback_base_url"

    /// Default matches `ApiClient` in personal_assistant_app (`personalassistantwebapp.onrender.com`).
    private static let defaultWhisperBaseURL = "https://personalassistantwebapp.onrender.com"

    static func whisperBaseURL() -> String {
        let trimmed = UserDefaults.standard.string(forKey: userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed.trimmingSuffixSlash
        }
        return defaultWhisperBaseURL
    }
}

private extension String {
    var trimmingSuffixSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
