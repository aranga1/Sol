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

    func save(_ prompt: String) async {
        isSaving = true
        errorMessage = nil
        do {
            let resp = try await APIClient.shared.updateSystemPrompt(prompt)
            systemPrompt = resp.systemPrompt
            saveSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

struct SettingsView: View {
    var onResetConnection: () -> Void

    @State private var vm = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                DS.parchmentMid.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        if let err = vm.errorMessage {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // ── Customisation ─────────────────────────────────
                        settingsSection(title: "Customisation") {
                            NavigationLink {
                                SystemPromptEditorView(
                                    initialText: vm.systemPrompt,
                                    defaultText: vm.defaultPrompt,
                                    onSave: { newPrompt in
                                        Task { await vm.save(newPrompt) }
                                    },
                                    onCancel: {}  // back button handles dismiss
                                )
                                .navigationBarHidden(true)
                            } label: {
                                settingsRowLabel(icon: "text.quote", label: "System Prompt")
                            }
                            .buttonStyle(.plain)
                        }

                        // ── Support ───────────────────────────────────────
                        settingsSection(title: nil) {
                            NavigationLink {
                                HelpView()
                                    .navigationBarHidden(true)
                            } label: {
                                settingsRowLabel(icon: "questionmark.circle", label: "Help")
                            }
                            .buttonStyle(.plain)
                        }

                        // ── Connection ────────────────────────────────────
                        settingsSection(title: "Connection") {
                            Button {
                                dismiss()
                                onResetConnection()
                            } label: {
                                settingsRowLabel(icon: "exclamationmark.triangle", label: "Reset Connection", isDestructive: true, chevron: false)
                            }
                            .buttonStyle(.plain)

                            Text("Clears your current Mac connection and returns to the QR setup screen.")
                                .font(.system(size: 13))
                                .foregroundStyle(DS.inkFaint)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(DS.inkLight)
                }
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(DS.newsreader(19, weight: .medium))
                        .foregroundStyle(DS.inkDark)
                }
            }
            .toolbarBackground(DS.parchmentMid, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
        // Sheet presentation style — partial reveal with home peeking at top
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.parchmentMid)
        .presentationCornerRadius(20)
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { vm.saveSuccess = false }
                    }
            }
        }
        .animation(.easeInOut, value: vm.saveSuccess)
        .task { await vm.load() }
    }

    // ── Row helpers ───────────────────────────────────────────────────────────
    @ViewBuilder
    private func settingsSection(title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(DS.inkFaint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) { content() }
                .background(DS.parchmentCard, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.inkDark.opacity(0.06), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func settingsRowLabel(
        icon: String,
        label: String,
        isDestructive: Bool = false,
        chevron: Bool = true
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(isDestructive ? DS.terracotta : DS.inkMid)
                .frame(width: 22)
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(isDestructive ? DS.terracotta : DS.inkDark)
            Spacer()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.inkFaint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}
