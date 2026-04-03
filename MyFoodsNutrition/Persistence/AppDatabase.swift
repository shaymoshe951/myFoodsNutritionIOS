import Foundation
import GRDB

final class AppDatabase {
    let dbQueue: DatabaseQueue

    static func open() throws -> AppDatabase {
        let url = try databaseURL()
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        var migrator = DatabaseMigrator()
        Migrations.register(&migrator)
        try migrator.migrate(queue)
        return AppDatabase(dbQueue: queue)
    }

    private static func databaseURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = dir.appendingPathComponent("MyFoodsNutrition", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("store.sqlite")
    }

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Sync state

    func getLastChangeLogId() throws -> Int64 {
        try dbQueue.read { db in
            let v = try String.fetchOne(
                db,
                sql: "SELECT value FROM sync_state WHERE key = ?",
                arguments: ["last_change_log_id"]
            )
            return Int64(v ?? "0") ?? 0
        }
    }

    func setLastChangeLogId(_ id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: ["last_change_log_id", String(id)]
            )
        }
    }

    // MARK: - Diary

    func itemsForDate(_ date: String) throws -> [DailyItemRecord] {
        try dbQueue.read { db in
            try DailyItemRecord
                .filter(DailyItemRecord.Columns.itmDate == date && DailyItemRecord.Columns.deleted == false)
                .order(DailyItemRecord.Columns.id.desc)
                .fetchAll(db)
        }
    }

    func insertItem(
        date: String,
        itemName: String,
        quantity: Int,
        mealTimeSlot: String,
        itmTime: String
    ) throws -> DailyItemRecord {
        let uuid = UUID().uuidString.lowercased()
        let now = ISO8601DateFormatter.syncFormatter.string(from: Date())
        var row = DailyItemRecord(
            id: nil,
            serverUid: nil,
            clientUuid: uuid,
            itmDate: date,
            itemName: itemName,
            quantity: quantity,
            mealTimeSlot: mealTimeSlot,
            itmTime: itmTime,
            updatedAt: now,
            deleted: false,
            needsPush: true
        )
        try dbQueue.write { db in
            try row.insert(db)
        }
        return row
    }

    func updateQuantity(id: Int64, quantity: Int) throws {
        let now = ISO8601DateFormatter.syncFormatter.string(from: Date())
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE daily_item SET quantity = ?, updated_at = ?, needs_push = 1
                WHERE id = ? AND deleted = 0
                """,
                arguments: [quantity, now, id]
            )
        }
    }

    /// Soft-delete if synced or pending sync; hard-delete if never pushed to server.
    func deleteItem(localId: Int64) throws {
        try dbQueue.write { db in
            guard var row = try DailyItemRecord.filter(DailyItemRecord.Columns.id == localId).fetchOne(db) else { return }
            if row.serverUid == nil {
                try row.delete(db)
                return
            }
            let now = ISO8601DateFormatter.syncFormatter.string(from: Date())
            row.deleted = true
            row.updatedAt = now
            row.needsPush = true
            try row.update(db)
        }
    }

    /// Rows that must be sent to the server (including soft-deleted with server uid).
    func pendingPushRows() throws -> [DailyItemRecord] {
        try dbQueue.read { db in
            try DailyItemRecord
                .filter(DailyItemRecord.Columns.needsPush == true)
                .order(DailyItemRecord.Columns.id.asc)
                .fetchAll(db)
        }
    }

    /// After a successful push: remove soft-deleted rows that were acknowledged, or clear `needs_push` and assign `server_uid` for upserts.
    func applyPushResponse(_ results: [DailyItemDTO.PushResult]) throws {
        try dbQueue.write { db in
            for r in results {
                guard var row = try DailyItemRecord
                    .filter(DailyItemRecord.Columns.clientUuid == r.client_uuid)
                    .fetchOne(db) else { continue }
                if row.deleted {
                    try row.delete(db)
                    continue
                }
                if let su = r.server_uid {
                    row.serverUid = su
                }
                if let ua = r.updated_at {
                    row.updatedAt = ua
                }
                row.needsPush = false
                try row.update(db)
            }
        }
    }

    /// Apply remote change log row (last-write-wins on `updated_at`).
    func applyRemoteChange(_ change: DailyItemDTO.ChangeRow) throws {
        guard change.entity_type == "daily_item" else { return }
        try dbQueue.write { db in
            if change.action == "delete", let uid = change.entity_uid {
                try db.execute(sql: "DELETE FROM daily_item WHERE server_uid = ?", arguments: [uid])
                return
            }
            guard change.action == "upsert",
                  let payload = change.payload,
                  let serverUid = payload.UID ?? change.entity_uid,
                  let itmDate = payload.itmDate,
                  let itemName = payload.itemName,
                  let quantity = payload.quantity,
                  let meal = payload.mealTimeSlot,
                  let itmTime = payload.itmTime,
                  let remoteUpdated = payload.updated_at
            else { return }

            if let existing = try DailyItemRecord.filter(DailyItemRecord.Columns.serverUid == serverUid).fetchOne(db) {
                if existing.updatedAt >= remoteUpdated { return }
                var next = existing
                next.itmDate = itmDate
                next.itemName = itemName
                next.quantity = quantity
                next.mealTimeSlot = meal
                next.itmTime = itmTime
                next.updatedAt = remoteUpdated
                next.deleted = payload.deleted_at != nil
                next.needsPush = false
                if next.deleted {
                    try next.delete(db)
                } else {
                    try next.update(db)
                }
                return
            }

            if let deletedAt = payload.deleted_at, !deletedAt.isEmpty {
                return
            }

            let uuid = UUID().uuidString.lowercased()
            var row = DailyItemRecord(
                id: nil,
                serverUid: serverUid,
                clientUuid: uuid,
                itmDate: itmDate,
                itemName: itemName,
                quantity: quantity,
                mealTimeSlot: meal,
                itmTime: itmTime,
                updatedAt: remoteUpdated,
                deleted: false,
                needsPush: false
            )
            try row.insert(db)
        }
    }
}

extension ISO8601DateFormatter {
    static let syncFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
