import Foundation
import WhisperKit
import Network

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case failed(String)
    case ready
    case transcribing
}

enum WhisperError: LocalizedError {
    case modelNotLoaded
    var errorDescription: String? { "Voice model not loaded. Please wait for download to complete." }
}

@Observable
@MainActor
final class WhisperService {
    static let shared = WhisperService()
    var modelState: ModelState = .notDownloaded
    private var whisper: WhisperKit?
    private let modelName = "base.en"

    func downloadModelIfNeeded() async {
        switch modelState {
        case .notDownloaded, .failed: break
        default: return
        }
        do {
            modelState = .downloading(progress: 0)
            whisper = try await WhisperKit(model: modelName)
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func retryDownload() async {
        modelState = .notDownloaded
        await downloadModelIfNeeded()
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard whisper != nil else { throw WhisperError.modelNotLoaded }
        modelState = .transcribing
        defer {
            modelState = .ready
            try? FileManager.default.removeItem(at: audioURL)
        }
        guard let results = try await whisper?.transcribe(audioPath: audioURL.path) else { return "" }
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
