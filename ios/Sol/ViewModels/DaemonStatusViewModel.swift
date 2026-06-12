import Foundation
import Combine

enum DaemonStatus { case checking, reachable, unreachable }

@Observable
@MainActor
final class DaemonStatusViewModel {
    var status: DaemonStatus = .checking
    private var timer: AnyCancellable?
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func startPolling() {
        checkNow()
        timer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkNow() }
    }

    func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    func checkNow() {
        Task { await ping() }
    }

    private func ping() async {
        do {
            let response = try await client.health()
            if status != .reachable { status = .reachable }
            // Persist vault name so the app can open the correct Obsidian vault
            if let name = response.vaultName, !name.isEmpty,
               var config = KeychainService.load(), config.vaultName != name {
                config.vaultName = name
                KeychainService.save(config)
            }
        } catch {
            if status != .unreachable { status = .unreachable }
        }
    }
}
