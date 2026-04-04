import Foundation

/// Mirrors `findItemDB.php` / `search-items.php` JSON.
struct FoodSearchResponse: Codable {
    var query: String
    var error: String
    var isStarCharInStr: Bool
    var nItemsFound: Int
    var items: [FoodSearchItemDTO]
    var queryTxtOnly: String?
    var numberInResult: Int?
    var requiredQuantity: Double?

    enum CodingKeys: String, CodingKey {
        case query
        case error
        case isStarCharInStr
        case nItemsFound = "n_items_found"
        case items
        case queryTxtOnly = "query_txt_only"
        case numberInResult = "number_in_result"
        case requiredQuantity = "required_quantity"
    }
}

struct FoodSearchItemDTO: Codable, Identifiable {
    var itemName: String
    var energy: Double?
    var itemUID: Int?

    var id: String { "\(itemUID ?? 0)-\(itemName)" }

    enum CodingKeys: String, CodingKey {
        case itemName
        case energy = "_energy"
        case itemUID
    }
}
