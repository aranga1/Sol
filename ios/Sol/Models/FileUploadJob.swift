import Foundation

enum FileUploadPhase: Equatable {
    case idle
    case reading
    case uploading(progress: Double)
    case success(filename: String)
    case failure(message: String)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.reading, .reading): return true
        case (.uploading(let a), .uploading(let b)): return abs(a - b) < 0.005
        case (.success(let a), .success(let b)): return a == b
        case (.failure(let a), .failure(let b)): return a == b
        default: return false
        }
    }
}

@MainActor
final class FileUploadJob: ObservableObject {
    @Published var phase: FileUploadPhase = .idle
    private(set) var pendingURL: URL?

    func start(url: URL) {
        pendingURL = url
        phase = .reading
        Task { await run(url: url) }
    }

    func retry() {
        guard let url = pendingURL else { return }
        start(url: url)
    }

    func dismiss() {
        pendingURL = nil
        phase = .idle
    }

    private func run(url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            phase = .failure(message: "Could not access the file. Try again.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            phase = .uploading(progress: 0)
            let onProgress: @Sendable (Double) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, case .uploading = self.phase else { return }
                    self.phase = .uploading(progress: progress)
                }
            }
            try await UploadService.shared.uploadFile(at: url, onProgress: onProgress)
            phase = .success(filename: url.lastPathComponent)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .success = phase { dismiss() }
        } catch {
            phase = .failure(message: error.localizedDescription)
        }
    }
}
