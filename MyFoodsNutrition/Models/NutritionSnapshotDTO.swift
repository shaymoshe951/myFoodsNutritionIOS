import Foundation

/// `GET /api/v1/nutrition-attributes.php` — DRI + labels + column order matching `table_items_data` / `updateDailyNutValues.php`.
struct NutritionSnapshotResponse: Codable {
    var generated_at: String?
    var nutrient_column_order: [String]
    var attributes: [String: NutritionAttributeEntryDTO]
}

struct NutritionAttributeEntryDTO: Codable {
    var dri_goal: Double
    var display_unit: String
    var label_he: String
}
