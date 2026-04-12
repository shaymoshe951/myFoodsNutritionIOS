import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let database: AppDatabase
    let apiClient: APIClient
    let syncEngine: SyncEngine
    private let networkMonitor: NetworkPathMonitor
    private var cancellables = Set<AnyCancellable>()

    init() {
        let config = APIConfig.load()
        let db = try! AppDatabase.open()
        let client = APIClient(config: config)
        self.database = db
        self.apiClient = client
        self.syncEngine = SyncEngine(database: db, apiClient: client)
        self.networkMonitor = NetworkPathMonitor()

        networkMonitor.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard connected else { return }
                Task { @MainActor in
                    await self?.syncEngine.flushPendingPushWhenOnline()
                }
            }
            .store(in: &cancellables)

        Task {
            await syncEngine.pullOnLaunchIfConfigured()
        }
    }

    func reloadAPIConfig() {
        apiClient.config = APIConfig.load()
    }

    /// Resets the stored `since_id` to 0 and runs sync so all `sync_change_log` rows are applied again (merges safely by server UID).
    func resyncFromFirstChangeLog() async throws {
        try database.resetSyncCursorForFullReplay()
        try await syncEngine.syncNow()
    }
}
