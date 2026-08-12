import Foundation

/// How many nutrients the image→AI flow should request and store.
enum ImageNutritionDetailLevel: String, CaseIterable, Identifiable {
    /// Calories + macros only (energy, protein, carbohydrate, fat).
    case basic
    /// Full nutrient profile including vitamins and minerals (keys from the synced nutrition snapshot when available).
    case detailed

    var id: String { rawValue }

    var labelHe: String {
        switch self {
        case .basic: return "עיקריים בלבד"
        case .detailed: return "מפורט (ויטמינים ומינרלים)"
        }
    }

    var footerHe: String {
        switch self {
        case .basic:
            return "קלוריות, חלבון, פחמימות ושומן ל־100 גרם."
        case .detailed:
            return "כל הרכיבים הזמינים במאפייני התזונה (כולל ויטמינים ומינרלים) ל־100 גרם."
        }
    }
}

/// OpenAI key + image-analysis detail preference (UserDefaults; optional Secrets.plist `OpenAIAPIKey`).
enum ImageNutritionSettings {
    private static let detailLevelKey = "image_nutrition_detail_level"
    private static let openAIKeyUserDefaults = "openai_api_key"
    private static let openAIModelUserDefaults = "openai_vision_model"

    static let defaultModel = "gpt-4o"

    static var detailLevel: ImageNutritionDetailLevel {
        get {
            let raw = UserDefaults.standard.string(forKey: detailLevelKey) ?? ""
            return ImageNutritionDetailLevel(rawValue: raw) ?? .basic
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: detailLevelKey)
        }
    }

    static var openAIAPIKey: String {
        get {
            let ud = UserDefaults.standard.string(forKey: openAIKeyUserDefaults)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !ud.isEmpty { return ud }
            return SecretsOpenAIKey.load() ?? ""
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: openAIKeyUserDefaults)
        }
    }

    static var visionModel: String {
        get {
            let m = UserDefaults.standard.string(forKey: openAIModelUserDefaults)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return m.isEmpty ? defaultModel : m
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? defaultModel : trimmed, forKey: openAIModelUserDefaults)
        }
    }

    static var isConfigured: Bool {
        !openAIAPIKey.isEmpty
    }

    static let basicNutrientKeys = ["energy", "protein", "carbohydrate", "total_lipid_fat"]
}

private enum SecretsOpenAIKey {
    static func load() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let key = (dict["OpenAIAPIKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }
}
