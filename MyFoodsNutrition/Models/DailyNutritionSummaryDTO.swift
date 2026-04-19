import Foundation

/// One row in the daily nutrition table (`updateDailyNutValues.php` / `daily-nutrition-summary.php`).
struct NutritionTableRow: Decodable, Identifiable {
    var nutrient_key: String
    var label_he: String
    var amount_text: String
    /// `nil` when the recommended intake is unknown (same as «לא ידוע» on the site).
    var percent: Int?

    var id: String { nutrient_key }
}

/// `POST /api/v1/daily-nutrition-summary.php` — same aggregation as `updateDailyNutValues.php`.
struct DailyNutritionSummaryDTO: Decodable {
    var date: String
    /// Keys such as `energy`, `protein`, `carbohydrate`, `total_lipid_fat`, `dietary_fiber` when present in DB.
    var totals: [String: Double]
    var labels_he: [String: String]?
    /// Full table for the day; filtered when `display_type` is `butBrief` (nutrients under 90% of DRI only).
    var nutrition_rows: [NutritionTableRow]?
    /// When DRI goals are known (local snapshot or API): nutrient key → % of recommended intake for the main strip (`energy`, `protein`, …).
    var dri_percent_by_key: [String: Int]?

    init(
        date: String,
        totals: [String: Double],
        labels_he: [String: String]? = nil,
        nutrition_rows: [NutritionTableRow]? = nil,
        dri_percent_by_key: [String: Int]? = nil
    ) {
        self.date = date
        self.totals = totals
        self.labels_he = labels_he
        self.nutrition_rows = nutrition_rows
        self.dri_percent_by_key = dri_percent_by_key
    }

    static let displayOrder = [
        "energy",
        "protein",
        "carbohydrate",
        "total_lipid_fat",
        "dietary_fiber",
    ]
}
