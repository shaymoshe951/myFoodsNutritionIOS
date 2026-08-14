import Foundation

/// Parsed result from vision AI for one food in an image (values are **per 100 g**).
struct FoodImageNutritionResult: Equatable, Identifiable {
    var id: String { "\(itemName)-\(quantityGrams)-\(nutrientsPer100g.count)" }
    var itemName: String
    /// Portion weight from the AI (editable before adding to the diary).
    var quantityGrams: Int
    /// Nutrient key → amount per 100 g (same keys as `food_catalog_item.nutrients_json`).
    var nutrientsPer100g: [String: Double]
    var notes: String?
    /// Optional on-device label / volume that produced this row.
    var sourceLabel: String?
    var volumeMl: Double?

    var energyPer100: Double? {
        nutrientsPer100g["energy"]
    }
}

struct FoodImageNutritionItemPayload: Decodable {
    var item_name: String?
    var quantity_grams: Double?
    var nutrients_per_100g: [String: Double]?
    var notes: String?
    var source_label: String?
    var volume_ml: Double?

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
            notes: (notesTrim?.isEmpty == false) ? notesTrim : nil,
            sourceLabel: source_label,
            volumeMl: volume_ml
        )
    }
}

/// Supports either a single object or `{ "items": [ ... ] }`.
struct FoodImageNutritionPayload: Decodable {
    var item_name: String?
    var quantity_grams: Double?
    var nutrients_per_100g: [String: Double]?
    var notes: String?
    var items: [FoodImageNutritionItemPayload]?

    func toResults() throws -> [FoodImageNutritionResult] {
        if let items, !items.isEmpty {
            return try items.map { try $0.toResult() }
        }
        return try [FoodImageNutritionItemPayload(
            item_name: item_name,
            quantity_grams: quantity_grams,
            nutrients_per_100g: nutrients_per_100g,
            notes: notes,
            source_label: nil,
            volume_ml: nil
        ).toResult()]
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
