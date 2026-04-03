import Foundation

/// JSON shapes expected from `POST /sync/push` and `GET /sync/pull` (PHP API).
enum DailyItemDTO {
    /// `op`: `upsert` | `delete`. For `delete`, only `client_uuid`, `server_uid`, `updated_at` are required server-side; other fields are sent as placeholders for a simple encoder.
    struct PushOperation: Encodable {
        var op: String
        var client_uuid: String
        var server_uid: Int64?
        var itm_date: String
        var item_name: String
        var quantity: Int
        var meal_time_slot: String
        var itm_time: String
        var updated_at: String
    }

    struct PushRequest: Encodable {
        var operations: [PushOperation]
    }

    struct PushResult: Decodable {
        var client_uuid: String
        var server_uid: Int64?
        var updated_at: String?
    }

    struct PushResponse: Decodable {
        var results: [PushResult]
    }

    struct ChangeRow: Decodable {
        var id: Int64
        var entity_type: String
        var entity_uid: Int64?
        var action: String
        var payload: Payload?
    }

    struct Payload: Decodable {
        var UID: Int64?
        var itmDate: String?
        var itemName: String?
        var quantity: Int?
        var mealTimeSlot: String?
        var itmTime: String?
        var updated_at: String?
        var deleted_at: String?
    }

    struct PullResponse: Decodable {
        var changes: [ChangeRow]
        var next_since_id: Int64?
    }
}
