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
}
