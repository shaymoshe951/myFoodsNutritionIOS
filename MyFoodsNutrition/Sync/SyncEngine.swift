import Foundation

@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncedAt: Date?

    private let database: AppDatabase
    private let apiClient: APIClient

    init(database: AppDatabase, apiClient: APIClient) {
        self.database = database
        self.apiClient = apiClient
    }

    /// Called on launch (if API configured) and when connectivity returns. Push is deferred until online; failures keep `needs_push`.
    func pullOnLaunchIfConfigured() async {
        guard apiClient.config.isConfigured else {
            AppLog.sync.info("pullOnLaunch skipped: API not configured")
            return
        }
        AppLog.sync.info("pullOnLaunch: flush push then pull")
        await flushPendingPushWhenOnline()
        await pullSilently()
    }

    /// When network becomes available, retry pending uploads.
    func flushPendingPushWhenOnline() async {
        guard apiClient.config.isConfigured else { return }
        do {
            try await pushPending()
            lastError = nil
        } catch {
            AppLog.sync.error("flushPendingPush failed: \(String(describing: error))")
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// User-initiated: push then pull. Throws so the UI can show an alert.
    func syncNow() async throws {
        guard apiClient.config.isConfigured else { throw APIError.notConfigured }
        AppLog.sync.info("syncNow start")
        isSyncing = true
        lastError = nil
        defer {
            isSyncing = false
            AppLog.sync.info("syncNow end")
        }
        do {
            try await pushPending()
        } catch {
            AppLog.sync.error("syncNow failed at pushPending: \(String(describing: error))")
            throw error
        }
        do {
            try await pullAndPersist()
        } catch {
            AppLog.sync.error("syncNow failed at pullAndPersist: \(String(describing: error))")
            throw error
        }
        lastSyncedAt = Date()
    }

    private func pullSilently() async {
        do {
            try await pullAndPersist()
            lastSyncedAt = Date()
            lastError = nil
        } catch {
            AppLog.sync.error("pullSilently failed: \(String(describing: error))")
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func pushPending() async throws {
        let rows = try database.pendingPushRows().filter { !$0.deleted || $0.serverUid != nil }
        guard !rows.isEmpty else {
            AppLog.sync.info("pushPending: nothing to upload")
            return
        }
        AppLog.sync.info("pushPending: uploading \(rows.count) row(s)")

        let ops: [DailyItemDTO.PushOperation] = rows.map { row in
            if row.deleted {
                return DailyItemDTO.PushOperation(
                    op: "delete",
                    client_uuid: row.clientUuid,
                    server_uid: row.serverUid,
                    itm_date: "",
                    item_name: "",
                    quantity: 0,
                    meal_time_slot: "",
                    itm_time: "",
                    updated_at: row.updatedAt
                )
            }
            return DailyItemDTO.PushOperation(
                op: "upsert",
                client_uuid: row.clientUuid,
                server_uid: row.serverUid,
                itm_date: row.itmDate,
                item_name: row.itemName,
                quantity: row.quantity,
                meal_time_slot: row.mealTimeSlot,
                itm_time: row.itmTime,
                updated_at: row.updatedAt
            )
        }

        let response = try await apiClient.push(operations: ops)
        try database.applyPushResponse(response.results)
        AppLog.sync.info("pushPending: server returned \(response.results.count) result(s)")
    }

    private func pullAndPersist() async throws {
        let since = try database.getLastChangeLogId()
        AppLog.sync.info("pullAndPersist: since_id=\(since)")
        let page = try await apiClient.pull(sinceId: since)
        AppLog.sync.info("pullAndPersist: received \(page.changes.count) change(s) next_since=\(page.next_since_id.map(String.init) ?? "nil")")
        var maxId = since
        for change in page.changes {
            do {
                try database.applyRemoteChange(change)
            } catch {
                AppLog.sync.error("applyRemoteChange failed id=\(change.id) action=\(change.action) entity=\(change.entity_uid.map(String.init) ?? "nil"): \(String(describing: error))")
                throw error
            }
            maxId = max(maxId, change.id)
        }
        if let next = page.next_since_id {
            maxId = max(maxId, next)
        }
        try database.setLastChangeLogId(maxId)
    }
}
