import Foundation
import WhisperKit
import Network

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
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
    private let modelName = "openai_whisper-base.en"  // WhisperKit model identifier

    private var modelCacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisperkit-models")
    }

    func downloadModelIfNeeded() async throws {
        guard case .notDownloaded = modelState else { return }
        let cachedPath = modelCacheURL.appendingPathComponent(modelName)
        if FileManager.default.fileExists(atPath: cachedPath.path) {
            try await loadModel(folder: cachedPath.path, download: false)
            return
        }
        try FileManager.default.createDirectory(at: modelCacheURL, withIntermediateDirectories: true)
        try await loadModel(folder: cachedPath.path, download: true)
    }

    private func loadModel(folder: String, download: Bool) async throws {
        modelState = .downloading(progress: 0)
        whisper = try await WhisperKit(
            WhisperKitConfig(
                model: modelName,
                modelFolder: folder,
                verbose: false,
                prewarm: true,
                load: true,
                download: download
            ) 
        )
        modelState = .ready
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
