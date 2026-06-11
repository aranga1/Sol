import Foundation
import Combine

enum DaemonStatus { case checking, reachable, unreachable }

@Observable
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
        status = .checking
        Task {
            do {
                _ = try await client.health()
                await MainActor.run { status = .reachable }
            } catch {
                await MainActor.run { status = .unreachable }
            }
        }
    }
}
