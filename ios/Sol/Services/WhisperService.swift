import Foundation
@preconcurrency import WhisperKit

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
    var liveTranscript = ""
    var isRecording = false

    private var whisper: WhisperKit?
    private let modelName = "base.en"
    private var transcriptionTimer: Timer?

    // MARK: - Model lifecycle

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

    // MARK: - Real-time recording

    func startRealtimeRecording() throws {
        guard case .ready = modelState, let whisper else { throw WhisperError.modelNotLoaded }

        liveTranscript = ""
        isRecording = true

        // WhisperKit owns the audio session for live recording
        try whisper.audioProcessor.startRecordingLive(inputDeviceID: nil) { _ in }

        // Transcribe every 3 seconds for live feedback
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.updateLiveTranscript() }
        }
    }

    private func updateLiveTranscript() async {
        guard let whisper, !whisper.audioProcessor.audioSamples.isEmpty else { return }
        let samples = Array(whisper.audioProcessor.audioSamples)
        guard samples.count > 3200 else { return }  // need at least 0.2s at 16kHz

        if let results = try? await whisper.transcribe(audioArray: samples) {
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { liveTranscript = text }
        }
    }

    func stopRealtimeRecording() async -> String {
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil

        guard let whisper else {
            isRecording = false
            return liveTranscript
        }

        let samples = Array(whisper.audioProcessor.audioSamples)
        whisper.audioProcessor.stopRecording()
        modelState = .transcribing

        // Final full-audio transcription pass
        if samples.count > 3200,
           let results = try? await whisper.transcribe(audioArray: samples) {
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { liveTranscript = text }
        }

        modelState = .ready
        isRecording = false
        return liveTranscript
    }
}
