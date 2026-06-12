import SwiftUI

@Observable
@MainActor
private final class SettingsViewModel {
    var systemPrompt = ""
    var defaultPrompt = ""
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var saveSuccess = false

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await APIClient.shared.getSystemPrompt()
            systemPrompt = resp.systemPrompt
            defaultPrompt = resp.defaultSystemPrompt
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func save() async {
        isSaving = true
        errorMessage = nil
        saveSuccess = false
        do {
            let resp = try await APIClient.shared.updateSystemPrompt(systemPrompt)
            systemPrompt = resp.systemPrompt
            saveSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    func resetToDefault() {
        systemPrompt = defaultPrompt
    }
}

struct SettingsView: View {
    var onResetConnection: () -> Void

    @State private var vm = SettingsViewModel()
    @State private var showHelp = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if vm.isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading…").foregroundStyle(.secondary)
                        }
                    } else {
                        TextEditor(text: $vm.systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 260)

                        Button("Reset to default") { vm.resetToDefault() }
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } header: {
                    Text("System Prompt")
                } footer: {
                    Text("Use {context_str} for retrieved note excerpts and {query_str} for the user's question. Changes take effect immediately.")
                        .font(.caption)
                }

                if let error = vm.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }

                Section {
                    Button {
                        showHelp = true
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    Button("Reset Connection", role: .destructive) {
                        dismiss()
                        onResetConnection()
                    }
                } footer: {
                    Text("Clears your current Mac connection and returns to the QR setup screen.")
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await vm.save() } }
                            .disabled(vm.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if vm.saveSuccess {
                    Text("Saved")
                        .font(.subheadline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                vm.saveSuccess = false
                            }
                        }
                }
            }
            .animation(.easeInOut, value: vm.saveSuccess)
            .task { await vm.load() }
            .sheet(isPresented: $showHelp) {
                HelpView()
            }
        }
    }
}
