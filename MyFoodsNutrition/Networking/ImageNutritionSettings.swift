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

/// Vision-capable OpenAI chat models offered in Settings.
enum OpenAIVisionModelOption: String, CaseIterable, Identifiable {
    case gpt56Sol = "gpt-5.6-sol"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Luna = "gpt-5.6-luna"
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case gpt41 = "gpt-4.1"
    case gpt41Mini = "gpt-4.1-mini"
    case gpt41Nano = "gpt-4.1-nano"

    var id: String { rawValue }

    var labelHe: String {
        switch self {
        case .gpt56Sol: return "GPT-5.6 Sol"
        case .gpt56Terra: return "GPT-5.6 Terra"
        case .gpt56Luna: return "GPT-5.6 Luna"
        case .gpt4o: return "GPT-4o"
        case .gpt4oMini: return "GPT-4o mini"
        case .gpt41: return "GPT-4.1"
        case .gpt41Mini: return "GPT-4.1 mini"
        case .gpt41Nano: return "GPT-4.1 nano"
        }
    }

    /// GPT-5.x chat models often reject `temperature`; use `reasoning_effort` instead.
    var usesReasoningAPIConstraints: Bool {
        rawValue.hasPrefix("gpt-5")
    }

    static var defaultOption: OpenAIVisionModelOption { .gpt4o }

    static func fromStoredModelId(_ raw: String) -> OpenAIVisionModelOption {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "gpt-5.6" { return .gpt56Sol }
        return OpenAIVisionModelOption(rawValue: trimmed) ?? .defaultOption
    }
}

/// OpenAI key + image-analysis detail preference (UserDefaults; optional Secrets.plist `OpenAIAPIKey`).
enum ImageNutritionSettings {
    private static let detailLevelKey = "image_nutrition_detail_level"
    private static let openAIKeyUserDefaults = "openai_api_key"
    private static let openAIModelUserDefaults = "openai_vision_model"

    static let defaultModel = OpenAIVisionModelOption.defaultOption.rawValue

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

    static var visionModelOption: OpenAIVisionModelOption {
        get { OpenAIVisionModelOption.fromStoredModelId(visionModel) }
        set { visionModel = newValue.rawValue }
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
