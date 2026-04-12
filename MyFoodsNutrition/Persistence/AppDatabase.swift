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

    /// Clears the stored `sync_change_log` cursor so the next pull replays from id 0 (merges safely by `server_uid`).
    func resetSyncCursorForFullReplay() throws {
        try setLastChangeLogId(0)
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
        itmTime: String,
        energyPer100: Double? = nil
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
            energyPer100: energyPer100,
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
                guard let cu = r.client_uuid, !cu.isEmpty else { continue }
                guard var row = try DailyItemRecord
                    .filter(DailyItemRecord.Columns.clientUuid == cu)
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
            guard change.action == "upsert", let payload = change.payload else {
                AppLog.sync.notice("applyRemoteChange: skip id=\(change.id) (not upsert or missing payload)")
                return
            }
            let serverUidOpt = payload.UID ?? change.entity_uid
            guard let serverUid = serverUidOpt else {
                AppLog.sync.notice("applyRemoteChange: skip id=\(change.id) (no UID)")
                return
            }
            guard let rawDate = payload.itmDate?.trimmingCharacters(in: .whitespacesAndNewlines), !rawDate.isEmpty else {
                AppLog.sync.notice("applyRemoteChange: skip id=\(change.id) uid=\(serverUid) (no itmDate)")
                return
            }
            let itmDate = Self.normalizeItmDate(rawDate)
            guard let itemName = payload.itemName?.trimmingCharacters(in: .whitespacesAndNewlines), !itemName.isEmpty else {
                AppLog.sync.notice("applyRemoteChange: skip id=\(change.id) uid=\(serverUid) (no itemName)")
                return
            }
            guard let remoteUpdated = payload.updated_at?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteUpdated.isEmpty else {
                AppLog.sync.notice("applyRemoteChange: skip id=\(change.id) uid=\(serverUid) (no updated_at)")
                return
            }
            let quantity = max(1, payload.quantity ?? 1)
            let meal = payload.mealTimeSlot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let itmTime = payload.itmTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "00:00"
            let deletedFlag: Bool = {
                guard let s = payload.deleted_at?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return false }
                return true
            }()

            if let existing = try DailyItemRecord.filter(DailyItemRecord.Columns.serverUid == serverUid).fetchOne(db) {
                if existing.updatedAt >= remoteUpdated { return }
                var next = existing
                next.itmDate = itmDate
                next.itemName = itemName
                next.quantity = quantity
                next.mealTimeSlot = meal
                next.itmTime = itmTime
                next.energyPer100 = existing.energyPer100
                next.updatedAt = remoteUpdated
                next.deleted = deletedFlag
                next.needsPush = false
                if next.deleted {
                    try next.delete(db)
                } else {
                    try next.update(db)
                }
                return
            }

            if deletedFlag {
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
                energyPer100: nil,
                updatedAt: remoteUpdated,
                deleted: false,
                needsPush: false
            )
            try row.insert(db)
        }
    }

    private static func normalizeItmDate(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10 else { return t }
        let head = String(t.prefix(10))
        return head.contains("-") ? head : t
    }

    // MARK: - Food catalog (offline mirror of `table_items_data`)

    func foodCatalogItemCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(FoodCatalogItemRecord.databaseTableName)") ?? 0
        }
    }

    func replaceFoodCatalog(with response: FoodCatalogResponse) throws {
        let enc = JSONEncoder()
        try dbQueue.write { db in
            try FoodCatalogItemRecord.deleteAll(db)
            for item in response.items {
                let jsonData = try enc.encode(item.nutrients)
                let json = String(data: jsonData, encoding: .utf8) ?? "{}"
                var row = FoodCatalogItemRecord(
                    serverUid: Int64(item.itemUID),
                    itemName: item.itemName,
                    isExtended: item.isExtended != 0,
                    nutrientsJson: json
                )
                try row.insert(db)
            }
            try db.execute(
                sql: """
                INSERT INTO sync_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: ["food_catalog_item_count", String(response.items.count)]
            )
        }
    }

    /// Local search using the same preprocessing as `nutrition_item_search()`; matching is substring + word tokens (SQLite has no MySQL `REGEXP`).
    func searchFoodCatalog(query raw: String) throws -> FoodSearchResponse {
        let parsed = FoodSearchQueryParser.parse(raw)
        var res = FoodSearchResponse(
            query: raw,
            error: parsed.error ?? "",
            isStarCharInStr: parsed.isStarCharInStr,
            nItemsFound: 0,
            items: [],
            queryTxtOnly: parsed.queryTxtOnly,
            numberInResult: parsed.numberInResult,
            requiredQuantity: parsed.requiredQuantity
        )
        if parsed.error == "too many numbers!" {
            return res
        }
        let qOnly = parsed.queryTxtOnly.trimmingCharacters(in: .whitespacesAndNewlines)
        if qOnly.isEmpty {
            return res
        }

        let words = qOnly.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        func matchesWords(_ name: String) -> Bool {
            guard !words.isEmpty else { return true }
            return words.allSatisfy { name.contains($0) }
        }

        let likeFrag = Self.sqlLikeFragment(containing: qOnly)
        let pattern = "%\(likeFrag)%"

        return try dbQueue.read { db in
            var rows: [FoodCatalogItemRecord] = []
            if !parsed.isStarCharInStr {
                rows = try Self.fetchCatalogCandidates(db: db, pattern: pattern, extendedNonOnly: true)
                rows = rows.filter { matchesWords($0.itemName) }
            }
            if rows.isEmpty {
                rows = try Self.fetchCatalogCandidates(db: db, pattern: pattern, extendedNonOnly: false)
                rows = rows.filter { matchesWords($0.itemName) }
            }

            let nFound = rows.count
            let limited = Array(rows.prefix(12))
            let decoder = JSONDecoder()
            let items: [FoodSearchItemDTO] = limited.map { r in
                let data = r.nutrientsJson.data(using: .utf8) ?? Data()
                let nut = (try? decoder.decode([String: Double].self, from: data)) ?? [:]
                return FoodSearchItemDTO(
                    itemName: r.itemName,
                    energy: nut["energy"],
                    itemUID: Int(r.serverUid)
                )
            }

            res.nItemsFound = nFound
            res.items = items
            return res
        }
    }

    /// Same nutrient aggregation as `daily-nutrition-summary.php` when diary rows resolve in `food_catalog_item`.
    func localNutritionSummaryIfAvailable(date: String) throws -> DailyNutritionSummaryDTO? {
        let rows = try itemsForDate(date)
        var arrNutValues: [String: Double] = [:]
        for row in rows {
            guard let nutrients = try nutrientsForItemName(row.itemName) else { continue }
            let quantity = Double(row.quantity)
            for (name, v) in nutrients where v > 0 {
                arrNutValues[name, default: 0] += v * quantity / 100.0
            }
        }

        let mainKeys = ["energy", "protein", "carbohydrate", "total_lipid_fat", "dietary_fiber"]
        var totals: [String: Double] = [:]
        for k in mainKeys {
            if let x = arrNutValues[k] {
                totals[k] = (x * 10).rounded() / 10
            }
        }
        if totals["dietary_fiber"] == nil, let f = arrNutValues["fiber"] {
            totals["dietary_fiber"] = (f * 10).rounded() / 10
        }
        if totals.isEmpty {
            return nil
        }
        let labelsHe: [String: String] = [
            "energy": "קלוריות",
            "protein": "חלבונים",
            "carbohydrate": "פחמימות",
            "total_lipid_fat": "שומנים",
            "dietary_fiber": "סיבים תזונתיים",
        ]
        return DailyNutritionSummaryDTO(date: date, totals: totals, labels_he: labelsHe)
    }

    private func nutrientsForItemName(_ name: String) throws -> [String: Double]? {
        try dbQueue.read { db in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let row = try FoodCatalogItemRecord
                .filter(FoodCatalogItemRecord.Columns.itemName == trimmed)
                .order(FoodCatalogItemRecord.Columns.serverUid.asc)
                .fetchOne(db)
            else {
                return nil
            }
            guard let data = row.nutrientsJson.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode([String: Double].self, from: data)
        }
    }

    private static func sqlLikeFragment(containing text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func fetchCatalogCandidates(
        db: Database,
        pattern: String,
        extendedNonOnly: Bool
    ) throws -> [FoodCatalogItemRecord] {
        var sql = """
        SELECT * FROM \(FoodCatalogItemRecord.databaseTableName)
        WHERE item_name LIKE ? ESCAPE '\\'
        """
        if extendedNonOnly {
            sql += " AND is_extended = 0"
        }
        sql += " LIMIT 500"
        return try FoodCatalogItemRecord.fetchAll(db, sql: sql, arguments: [pattern])
    }
}

extension ISO8601DateFormatter {
    static let syncFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
