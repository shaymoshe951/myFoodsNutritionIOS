import Foundation

/// `POST /api/v1/daily-nutrition-summary.php` — same aggregation as `updateDailyNutValues.php`.
struct DailyNutritionSummaryDTO: Decodable {
    var date: String
    /// Keys such as `energy`, `protein`, `carbohydrate`, `total_lipid_fat`, `dietary_fiber` when present in DB.
    var totals: [String: Double]
    var labels_he: [String: String]?

    init(date: String, totals: [String: Double], labels_he: [String: String]? = nil) {
        self.date = date
        self.totals = totals
        self.labels_he = labels_he
    }

    static let displayOrder = [
        "energy",
        "protein",
        "carbohydrate",
        "total_lipid_fat",
        "dietary_fiber",
    ]
}
