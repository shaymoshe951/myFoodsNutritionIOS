import Foundation

/// `GET/POST /api/v1/catalog-items.php`
struct FoodCatalogResponse: Codable {
    var generated_at: String?
    var item_count: Int?
    var items: [FoodCatalogItemDTO]
}

struct FoodCatalogItemDTO: Codable {
    var itemUID: Int
    var itemName: String
    var isExtended: Int
    var nutrients: [String: Double]
}

// MARK: - Same parsing rules as `api/v1/includes/item_search.php`

enum FoodSearchQueryParser {
    struct Parsed {
        var error: String?
        var isStarCharInStr: Bool
        var queryTxtOnly: String
        var numberInResult: Int
        var requiredQuantity: Double?
    }

    /// Mirrors `nutrition_item_search()` preprocessing of `$rawQuery` (before SQL).
    static func parse(_ rawQuery: String) -> Parsed {
        var q = rawQuery
        let isStar = q.contains("*")
        if isStar {
            q = q.replacingOccurrences(of: "*", with: "")
        }
        q = q.replacingOccurrences(of: "גרם", with: "")

        let numberPattern = try! NSRegularExpression(pattern: #"\d+\.?\d?"#, options: [])
        let ns = q as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = numberPattern.matches(in: q, options: [], range: fullRange)

        if matches.count > 1 {
            return Parsed(
                error: "too many numbers!",
                isStarCharInStr: isStar,
                queryTxtOnly: "",
                numberInResult: 0,
                requiredQuantity: nil
            )
        }

        var numberInResult = 0
        var requiredQuantity: Double?
        if matches.count == 1 {
            let r = matches[0].range
            let numStr = ns.substring(with: r)
            requiredQuantity = Double(numStr.replacingOccurrences(of: ",", with: "."))
            numberInResult = 1
            q = ns.replacingCharacters(in: r, with: "")
        }

        let ws = try! NSRegularExpression(pattern: "\\s+", options: [])
        q = ws.stringByReplacingMatches(in: q, options: [], range: NSRange(location: 0, length: (q as NSString).length), withTemplate: " ")
        q = q.trimmingCharacters(in: .whitespacesAndNewlines)

        return Parsed(
            error: nil,
            isStarCharInStr: isStar,
            queryTxtOnly: q,
            numberInResult: numberInResult,
            requiredQuantity: requiredQuantity
        )
    }
}
