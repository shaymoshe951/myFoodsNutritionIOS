import Combine
import Foundation
import Network

/// Publishes connectivity; when the path becomes satisfied, the app retries pending push (`AppModel` wires this to `SyncEngine`).
final class NetworkPathMonitor: ObservableObject {
    @Published private(set) var isConnected: Bool

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.myFoodsNutrition.network")

    init() {
        monitor = NWPathMonitor()
        isConnected = monitor.currentPath.status == .satisfied
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isConnected = ok
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
