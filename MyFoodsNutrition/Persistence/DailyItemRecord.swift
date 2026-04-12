import Foundation
import GRDB

struct DailyItemRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "daily_item"

    var id: Int64?
    var serverUid: Int64?
    var clientUuid: String
    var itmDate: String
    var itemName: String
    var quantity: Int
    var mealTimeSlot: String
    var itmTime: String
    /// kcal per 100g from food DB when the row was added via in-app search; nil for items synced from server or legacy rows.
    var energyPer100: Double?
    /// ISO8601 with fractional seconds, UTC or server format; compared lexicographically for LWW.
    var updatedAt: String
    var deleted: Bool
    var needsPush: Bool

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let serverUid = Column(CodingKeys.serverUid)
        static let clientUuid = Column(CodingKeys.clientUuid)
        static let itmDate = Column(CodingKeys.itmDate)
        static let itemName = Column(CodingKeys.itemName)
        static let quantity = Column(CodingKeys.quantity)
        static let mealTimeSlot = Column(CodingKeys.mealTimeSlot)
        static let itmTime = Column(CodingKeys.itmTime)
        static let energyPer100 = Column(CodingKeys.energyPer100)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let deleted = Column(CodingKeys.deleted)
        static let needsPush = Column(CodingKeys.needsPush)
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case serverUid = "server_uid"
        case clientUuid = "client_uuid"
        case itmDate = "itm_date"
        case itemName = "item_name"
        case quantity
        case mealTimeSlot = "meal_time_slot"
        case itmTime = "itm_time"
        case energyPer100 = "energy_per_100"
        case updatedAt = "updated_at"
        case deleted
        case needsPush = "needs_push"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
