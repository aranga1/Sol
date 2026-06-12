import SwiftUI

@Observable
@MainActor
private final class VoiceNoteViewModel {
    var title = ""
    var editableTranscript = ""
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

    // When non-empty, pre-fills the transcript and skips recording UI
    var initialTranscript: String

    init(initialTranscript: String = "") {
        self.initialTranscript = initialTranscript
    }

    private var isVoiceFlow: Bool { !initialTranscript.isEmpty }
    private var sheetTitle: String { isVoiceFlow ? "Voice Note" : "New Note" }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.parchmentMid.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Transcribed-from-voice badge (only in voice flow)
                    if isVoiceFlow {
                        transcribedBadge
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Model state views (only in recording flow)
                    if !isVoiceFlow {
                        if case .downloading = vm.whisperService.modelState {
                            modelDownloadingView
                                .padding(.top, 32)
                        } else if case .failed(let reason) = vm.whisperService.modelState {
                            modelFailedView(reason: reason)
                                .padding(.top, 32)
                        } else if vm.isFinalizing {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .tint(DS.terracotta)
                                Text("Finalizing transcript\u{2026}")
                                    .font(.system(size: 15))
                                    .foregroundStyle(DS.inkFaint)
                            }
                            .padding(.top, 32)
                            .padding()
                        } else if !vm.isRecording && vm.editableTranscript.isEmpty {
                            // Record button
                            recordButton
                                .padding(.top, 32)
                        }
                    }

                    // Note fields: title + body — shown when there's content
                    if !vm.editableTranscript.isEmpty || isVoiceFlow {
                        noteFields
                    }

                    // Live transcript while recording (non-voice flow)
                    if !isVoiceFlow && vm.isRecording && !vm.liveTranscript.isEmpty {
                        Text(vm.liveTranscript)
                            .font(.body)
                            .foregroundStyle(DS.inkFaint)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                DS.parchmentCard,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .padding(.horizontal, 20)
                            .animation(.easeInOut, value: vm.liveTranscript)
                    }

                    // Re-record button (non-voice flow, after recording)
                    if !isVoiceFlow && !vm.isRecording && !vm.editableTranscript.isEmpty && !vm.isFinalizing {
                        Button {
                            Task {
                                vm.startRecording()
                            }
                        } label: {
                            Text("Re-record")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DS.inkFaint)
                        }
                        .padding(.top, 12)
                    }

                    // Stop recording button (non-voice flow, recording active)
                    if !isVoiceFlow && vm.isRecording {
                        stopRecordButton
                            .padding(.top, 24)
                    }

                    if let error = vm.errorMessage {
                        Text(error)
                            .foregroundStyle(DS.terracotta)
                            .font(.caption)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    Spacer()
                }
            }
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DS.parchmentMid, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(sheetTitle)
                        .font(DS.newsreader(19))
                        .foregroundStyle(DS.inkDark)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(DS.inkFaint)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isSending {
                        ProgressView()
                            .tint(DS.terracotta)
                    } else {
                        Button("Send") {
                            Task {
                                await vm.send()
                                if vm.errorMessage == nil { dismiss() }
                            }
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(DS.terracotta)
                        .disabled(
                            vm.editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || vm.isRecording || vm.isFinalizing
                        )
                    }
                }
            }
            .onAppear {
                if isVoiceFlow {
                    vm.editableTranscript = initialTranscript
                } else {
                    Task { await vm.whisperService.downloadModelIfNeeded() }
                }
            }
        }
    }

    // MARK: - Transcribed badge

    private var transcribedBadge: some View {
        HStack(spacing: 9) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "#CE4B2E"))
            Text("Transcribed from voice")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.terracottaDark)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            DS.terracotta.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(DS.terracotta.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Note fields

    private var noteFields: some View {
        VStack(spacing: 0) {
            // Title field
            TextField("Add a title (optional)", text: $vm.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DS.inkDark)
                .tint(DS.terracotta)
                .padding(.horizontal, 20)
                .padding(.top, isVoiceFlow ? 0 : 24)
                .padding(.bottom, 14)

            Rectangle()
                .fill(DS.inkDark.opacity(0.09))
                .frame(height: 1)
                .padding(.horizontal, 20)

            // Body editor
            TextEditor(text: $vm.editableTranscript)
                .font(.system(size: 17))
                .foregroundStyle(DS.inkDark)
                .tint(DS.terracotta)
                .lineSpacing(17 * 0.6 * 0.4)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxHeight: 320)
        }
    }

    // MARK: - Record button

    private var recordButton: some View {
        VStack(spacing: 14) {
            Button {
                vm.startRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(DS.terracottaGradient)
                        .frame(width: 88, height: 88)
                        .shadow(color: DS.terracotta.opacity(0.38), radius: 18, x: 0, y: 6)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
            }

            Text("Tap to record")
                .font(.system(size: 15))
                .foregroundStyle(DS.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Stop record button

    private var stopRecordButton: some View {
        VStack(spacing: 14) {
            Button {
                Task { await vm.stopRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#CE4B2E"))
                        .frame(width: 88, height: 88)
                        .shadow(color: Color(hex: "#CE4B2E").opacity(0.38), radius: 18, x: 0, y: 6)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
            }

            Text("Tap to stop")
                .font(.system(size: 15))
                .foregroundStyle(DS.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Model state views

    private var modelDownloadingView: some View {
        VStack(spacing: 8) {
            Text("Downloading voice model\u{2026}")
                .font(.subheadline)
                .foregroundStyle(DS.inkFaint)
            ProgressView()
                .tint(DS.terracotta)
                .padding(.top, 4)
            Text("~147 MB \u{2014} this only happens once")
                .font(.caption)
                .foregroundStyle(DS.inkFaint.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func modelFailedView(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(DS.amber)
            Text("Download failed")
                .font(.headline)
                .foregroundStyle(DS.inkDark)
            Text(reason)
                .font(.caption)
                .foregroundStyle(DS.inkFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                Task { await vm.whisperService.retryDownload() }
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.terracotta)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
