import Foundation
import GRDB

struct FoodCatalogItemRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "food_catalog_item"

    var serverUid: Int64
    var itemName: String
    var isExtended: Bool
    var nutrientsJson: String

    enum CodingKeys: String, CodingKey {
        case serverUid = "server_uid"
        case itemName = "item_name"
        case isExtended = "is_extended"
        case nutrientsJson = "nutrients_json"
    }

    enum Columns {
        static let serverUid = Column(CodingKeys.serverUid)
        static let itemName = Column(CodingKeys.itemName)
        static let isExtended = Column(CodingKeys.isExtended)
        static let nutrientsJson = Column(CodingKeys.nutrientsJson)
    }
}
