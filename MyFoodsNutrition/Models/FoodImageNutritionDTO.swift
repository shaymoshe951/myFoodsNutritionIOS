import Foundation

/// Parsed result from vision AI for one food in an image (values are **per 100 g**).
struct FoodImageNutritionResult: Equatable {
    var itemName: String
    var quantityGrams: Int
    /// Nutrient key → amount per 100 g (same keys as `food_catalog_item.nutrients_json`).
    var nutrientsPer100g: [String: Double]
    var notes: String?

    var energyPer100: Double? {
        nutrientsPer100g["energy"]
    }
}

struct FoodImageNutritionPayload: Decodable {
    var item_name: String?
    var quantity_grams: Double?
    var nutrients_per_100g: [String: Double]?
    var notes: String?

    func toResult() throws -> FoodImageNutritionResult {
        let name = (item_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw FoodImageNutritionError.invalidPayload("חסר שם מזון בתשובת ה־AI.")
        }
        let qtyRaw = quantity_grams ?? 100
        let qty = max(1, Int(qtyRaw.rounded()))
        let nuts = nutrients_per_100g ?? [:]
        guard !nuts.isEmpty else {
            throw FoodImageNutritionError.invalidPayload("חסרים ערכים תזונתיים בתשובת ה־AI.")
        }
        let notesTrim = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FoodImageNutritionResult(
            itemName: name,
            quantityGrams: qty,
            nutrientsPer100g: nuts,
            notes: (notesTrim?.isEmpty == false) ? notesTrim : nil
        )
    }
}

enum FoodImageNutritionError: LocalizedError {
    case notConfigured
    case invalidImage
    case invalidURL
    case badResponse
    case http(Int, String)
    case emptyContent
    case invalidPayload(String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "לא הוגדר מפתח OpenAI. הוסף אותו בהגדרות (או ב־Secrets.plist)."
        case .invalidImage:
            return "לא ניתן לעבד את התמונה."
        case .invalidURL:
            return "כתובת API של OpenAI לא תקינה."
        case .badResponse:
            return "תגובת שרת לא צפויה מ־OpenAI."
        case let .http(code, preview):
            return "ניתוח תמונה נכשל (\(code)): \(preview)"
        case .emptyContent:
            return "ה־AI לא החזיר תוכן."
        case let .invalidPayload(msg):
            return msg
        case let .decoding(err):
            return "פענוח תשובת ה־AI נכשל: \(err.localizedDescription)"
        }
    }
}
