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
        var client_uuid: String?
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

    /// PHP / MySQL may emit numbers as doubles or ints; decode flexibly to avoid typeMismatch.
    struct Payload: Decodable {
        var UID: Int64?
        var itmDate: String?
        var itemName: String?
        var quantity: Int?
        var mealTimeSlot: String?
        var itmTime: String?
        var updated_at: String?
        var deleted_at: String?

        enum CodingKeys: String, CodingKey {
            case UID
            case itmDate
            case itemName
            case quantity
            case mealTimeSlot
            case itmTime
            case updated_at
            case deleted_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            UID = try Self.decodeInt64Lenient(c, key: .UID)
            itmDate = try Self.decodeStringLenient(c, key: .itmDate)
            itemName = try Self.decodeStringLenient(c, key: .itemName)
            quantity = try Self.decodeIntLenient(c, key: .quantity)
            mealTimeSlot = try Self.decodeStringLenient(c, key: .mealTimeSlot)
            itmTime = try Self.decodeStringLenient(c, key: .itmTime)
            updated_at = try Self.decodeStringLenient(c, key: .updated_at)
            deleted_at = try Self.decodeStringLenient(c, key: .deleted_at)
        }

        private static func decodeInt64Lenient(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Int64? {
            if c.contains(key) == false { return nil }
            if let v = try? c.decode(Int64.self, forKey: key) { return v }
            if let v = try? c.decode(Int.self, forKey: key) { return Int64(v) }
            if let v = try? c.decode(Double.self, forKey: key) { return Int64(v) }
            if let s = try? c.decode(String.self, forKey: key), let v = Int64(s.trimmingCharacters(in: .whitespaces)) {
                return v
            }
            return nil
        }

        private static func decodeIntLenient(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Int? {
            if c.contains(key) == false { return nil }
            if let v = try? c.decode(Int.self, forKey: key) { return v }
            if let v = try? c.decode(Int64.self, forKey: key) { return Int(v) }
            if let v = try? c.decode(Double.self, forKey: key) { return Int(v.rounded(.towardZero)) }
            if let s = try? c.decode(String.self, forKey: key), let v = Int(s.trimmingCharacters(in: .whitespaces)) {
                return v
            }
            return nil
        }

        private static func decodeStringLenient(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> String? {
            if c.contains(key) == false { return nil }
            if let s = try? c.decode(String.self, forKey: key) { return s }
            if let n = try? c.decode(Int.self, forKey: key) { return String(n) }
            if let n = try? c.decode(Double.self, forKey: key) { return String(n) }
            if let b = try? c.decode(Bool.self, forKey: key) { return b ? "1" : "0" }
            return nil
        }
    }

    struct PullResponse: Decodable {
        var changes: [ChangeRow]
        var next_since_id: Int64?

        enum CodingKeys: String, CodingKey {
            case changes
            case next_since_id
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            changes = try c.decodeIfPresent([ChangeRow].self, forKey: .changes) ?? []
            next_since_id = try Self.decodeInt64Lenient(c, key: .next_since_id)
        }

        private static func decodeInt64Lenient(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Int64? {
            if c.contains(key) == false { return nil }
            if let v = try? c.decode(Int64.self, forKey: key) { return v }
            if let v = try? c.decode(Int.self, forKey: key) { return Int64(v) }
            if let v = try? c.decode(Double.self, forKey: key) { return Int64(v) }
            if let s = try? c.decode(String.self, forKey: key), let v = Int64(s.trimmingCharacters(in: .whitespaces)) {
                return v
            }
            return nil
        }
    }
}

// MARK: - ChangeRow lenient id / entity_uid (PHP may emit int or float JSON numbers)

extension DailyItemDTO.ChangeRow {
    enum ChangeCodingKeys: String, CodingKey {
        case id
        case entity_type
        case entity_uid
        case action
        case payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ChangeCodingKeys.self)
        id = try Self.decodeInt64Required(c, key: .id)
        entity_type = try c.decode(String.self, forKey: .entity_type)
        entity_uid = try Self.decodeInt64Optional(c, key: .entity_uid)
        action = try c.decode(String.self, forKey: .action)
        payload = try c.decodeIfPresent(DailyItemDTO.Payload.self, forKey: .payload)
    }

    private static func decodeInt64Required(_ c: KeyedDecodingContainer<ChangeCodingKeys>, key: ChangeCodingKeys) throws -> Int64 {
        if let v = try? c.decode(Int64.self, forKey: key) { return v }
        if let v = try? c.decode(Int.self, forKey: key) { return Int64(v) }
        if let v = try? c.decode(Double.self, forKey: key) { return Int64(v) }
        if let s = try? c.decode(String.self, forKey: key), let v = Int64(s.trimmingCharacters(in: .whitespaces)) {
            return v
        }
        throw DecodingError.typeMismatch(
            Int64.self,
            .init(codingPath: c.codingPath + [key], debugDescription: "Expected int-like id")
        )
    }

    private static func decodeInt64Optional(_ c: KeyedDecodingContainer<ChangeCodingKeys>, key: ChangeCodingKeys) throws -> Int64? {
        if c.contains(key) == false { return nil }
        if try c.decodeNil(forKey: key) { return nil }
        return try decodeInt64Required(c, key: key)
    }
}
