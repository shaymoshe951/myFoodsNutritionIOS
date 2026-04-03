import Foundation

struct APIConfig: Equatable {
    var baseURL: String
    var token: String

    var isConfigured: Bool {
        !baseURL.isEmpty && !token.isEmpty
    }

    static func load() -> APIConfig {
        let defaults = UserDefaults.standard
        let udBase = defaults.string(forKey: Keys.baseURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let udToken = defaults.string(forKey: Keys.token)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !udBase.isEmpty, !udToken.isEmpty {
            return APIConfig(baseURL: udBase.trimmingSuffixSlash, token: udToken)
        }

        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return APIConfig(baseURL: "", token: "")
        }

        let base = (dict["APIBaseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = (dict["APIToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return APIConfig(baseURL: base.trimmingSuffixSlash, token: token)
    }

    func saveToUserDefaults() {
        let d = UserDefaults.standard
        d.set(baseURL, forKey: Keys.baseURL)
        d.set(token, forKey: Keys.token)
    }

    private enum Keys {
        static let baseURL = "api_base_url"
        static let token = "api_token"
    }
}

private extension String {
    var trimmingSuffixSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
