import Foundation
import GRDB

enum Migrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("daily_item_v1") { db in
            try db.create(table: DailyItemRecord.databaseTableName, ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("server_uid", .integer).unique()
                t.column("client_uuid", .text).notNull().unique()
                t.column("itm_date", .text).notNull()
                t.column("item_name", .text).notNull()
                t.column("quantity", .integer).notNull()
                t.column("meal_time_slot", .text).notNull()
                t.column("itm_time", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("needs_push", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "idx_daily_item_date", on: DailyItemRecord.databaseTableName, columns: ["itm_date"], ifNotExists: true)
        }

        migrator.registerMigration("sync_state_v1") { db in
            try db.create(table: "sync_state", ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
    }
}
