import SwiftUI
import AVFoundation

@Observable
@MainActor
private final class VoiceNoteViewModel {
    var transcript = ""
    var isRecording = false
    var isTranscribing = false
    var isSending = false
    var errorMessage: String?
    private var audioRecorder: AVAudioRecorder?
    private var audioURL: URL?
    let whisperService = WhisperService.shared

    func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            audioURL = url
            isRecording = true
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecordingAndTranscribe() async {
        audioRecorder?.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        guard let url = audioURL else { return }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            transcript = try await whisperService.transcribe(audioURL: url)
            audioURL = nil
        } catch {
            errorMessage = error.localizedDescription
            cleanupAudio()
        }
    }

    func send() async {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        errorMessage = nil
        do {
            _ = try await APIClient.shared.submitNote(
                NoteRequest(content: transcript, title: nil, tags: nil, source: .voice)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = false
    }

    func cleanupAudio() {
        if let url = audioURL {
            try? FileManager.default.removeItem(at: url)
            audioURL = nil
        }
    }
}

struct VoiceNoteView: View {
    @State private var vm = VoiceNoteViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Model download progress / error
                if case .downloading = vm.whisperService.modelState {
                    VStack(spacing: 8) {
                        Text("Downloading voice model\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ProgressView()
                            .padding(.top, 4)
                        Text("~147 MB — this only happens once")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                } else if case .failed(let reason) = vm.whisperService.modelState {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("Download failed")
                            .font(.headline)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Try Again") {
                            Task { await vm.whisperService.retryDownload() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if vm.isTranscribing {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Transcribing\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    // Record button
                    Button {
                        Task {
                            if vm.isRecording {
                                await vm.stopRecordingAndTranscribe()
                            } else {
                                vm.startRecording()
                            }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(vm.isRecording ? Color.red : Color.indigo)
                                .frame(width: 100, height: 100)
                            Image(systemName: vm.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white)
                        }
                    }
                    .disabled(vm.isTranscribing)

                    Text(vm.isRecording ? "Tap to stop" : "Hold to record")
                        .foregroundStyle(.secondary)
                }

                // Transcript editor
                if !vm.transcript.isEmpty {
                    TextEditor(text: $vm.transcript)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                }

                if let error = vm.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Voice Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        vm.cleanupAudio()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isSending {
                        ProgressView()
                    } else {
                        Button("Send") {
                            Task {
                                await vm.send()
                                if vm.errorMessage == nil {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(vm.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isTranscribing)
                    }
                }
            }
            .onAppear {
                Task { await vm.whisperService.downloadModelIfNeeded() }
            }
            .onDisappear { vm.cleanupAudio() }
        }
    }
}
