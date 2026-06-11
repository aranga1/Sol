import SwiftUI

@Observable
@MainActor
private final class VoiceNoteViewModel {
    var title = ""
    var editableTranscript = ""  // user can edit after recording
    var isFinalizing = false
    var isSending = false
    var errorMessage: String?
    let whisperService = WhisperService.shared

    var isRecording: Bool { whisperService.isRecording }
    var liveTranscript: String { whisperService.liveTranscript }

    func startRecording() {
        errorMessage = nil
        editableTranscript = ""
        do {
            try whisperService.startRealtimeRecording()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        isFinalizing = true
        let final = await whisperService.stopRealtimeRecording()
        editableTranscript = final
        isFinalizing = false
    }

    func send() async {
        let content = editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSending = true
        errorMessage = nil
        do {
            _ = try await APIClient.shared.submitNote(
                NoteRequest(
                    content: content,
                    title: title.isEmpty ? nil : title,
                    tags: nil,
                    source: .voice
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = false
    }
}

struct VoiceNoteView: View {
    @State private var vm = VoiceNoteViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                // ── Model states ──────────────────────────────────────────────
                if case .downloading = vm.whisperService.modelState {
                    modelDownloadingView
                } else if case .failed(let reason) = vm.whisperService.modelState {
                    modelFailedView(reason: reason)

                // ── Finalizing (final transcription pass) ─────────────────────
                } else if vm.isFinalizing {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Finalizing transcript…")
                            .foregroundStyle(.secondary)
                    }
                    .padding()

                // ── Main recording / transcript UI ────────────────────────────
                } else {
                    // Record button
                    Button {
                        Task {
                            if vm.isRecording {
                                await vm.stopRecording()
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

                    Text(vm.isRecording ? "Tap to stop" : (vm.editableTranscript.isEmpty ? "Tap to record" : "Tap to re-record"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Live transcript while recording
                    if vm.isRecording && !vm.liveTranscript.isEmpty {
                        Text(vm.liveTranscript)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                            .animation(.easeInOut, value: vm.liveTranscript)
                    }

                    // Editable transcript + title after recording
                    if !vm.isRecording && !vm.editableTranscript.isEmpty {
                        VStack(spacing: 12) {
                            TextEditor(text: $vm.editableTranscript)
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal)

                            TextField("Add a title (optional)", text: $vm.title)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)
                        }
                    }
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isSending {
                        ProgressView()
                    } else {
                        Button("Send") {
                            Task {
                                await vm.send()
                                if vm.errorMessage == nil { dismiss() }
                            }
                        }
                        .disabled(
                            vm.editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || vm.isRecording || vm.isFinalizing
                        )
                    }
                }
            }
            .onAppear {
                Task { await vm.whisperService.downloadModelIfNeeded() }
            }
        }
    }

    private var modelDownloadingView: some View {
        VStack(spacing: 8) {
            Text("Downloading voice model…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView().padding(.top, 4)
            Text("~147 MB — this only happens once")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private func modelFailedView(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Download failed").font(.headline)
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
    }
}
