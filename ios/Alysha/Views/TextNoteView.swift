import SwiftUI

@Observable
@MainActor
private final class TextNoteViewModel {
    var content = ""
    var title = ""
    var isLoading = false
    var errorMessage: String?

    func send() async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let request = NoteRequest(
                content: content,
                title: title.isEmpty ? nil : title,
                tags: nil,
                source: .text
            )
            _ = try await APIClient.shared.submitNote(request)
            // Success — caller dismisses
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct TextNoteView: View {
    @State private var vm = TextNoteViewModel()
    @Environment(\.dismiss) private var dismiss
    // Callback invoked on success so caller can dismiss and show toast
    var onSuccess: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Title (optional)", text: $vm.title)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground))

                Divider()

                TextEditor(text: $vm.content)
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)

                if let error = vm.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isLoading {
                        ProgressView()
                    } else {
                        Button("Send") {
                            Task {
                                await vm.send()
                                if vm.errorMessage == nil {
                                    onSuccess?()
                                    dismiss()
                                }
                            }
                        }
                        .disabled(vm.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            // Keyboard auto-focus handled by the TextEditor being the primary view
        }
    }
}
