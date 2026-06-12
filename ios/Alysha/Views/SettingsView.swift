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
    var onDismiss: () -> Void

    @State private var vm = SettingsViewModel()
    @State private var showHelp = false
    @State private var showPromptEditor = false

    var body: some View {
        ZStack {
            DS.parchmentMid.ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(DS.inkDark.opacity(0.18))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                // Header
                HStack {
                    Button("Cancel") { onDismiss() }
                        .font(.system(size: 16))
                        .foregroundStyle(DS.inkLight)
                    Spacer()
                    Text("Settings")
                        .font(DS.newsreader(19, weight: .medium))
                        .foregroundStyle(DS.inkDark)
                    Spacer()
                    // Placeholder to balance Cancel
                    Text("Cancel").font(.system(size: 16)).foregroundStyle(.clear)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                if let err = vm.errorMessage {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                ScrollView {
                    VStack(spacing: 24) {
                        // ── Customisation ────────────────────────────────────
                        settingsSection(title: "Customisation") {
                            settingsRow(
                                icon: "text.quote",
                                label: "System Prompt",
                                chevron: true
                            ) {
                                showPromptEditor = true
                            }
                        }

                        // ── Support ──────────────────────────────────────────
                        settingsSection(title: nil) {
                            settingsRow(icon: "questionmark.circle", label: "Help", chevron: true) {
                                showHelp = true
                            }
                        }

                        // ── Connection ───────────────────────────────────────
                        settingsSection(title: "Connection") {
                            settingsRow(icon: "exclamationmark.triangle", label: "Reset Connection", isDestructive: true) {
                                onDismiss()
                                onResetConnection()
                            }
                            Text("Clears your current Mac connection and returns to the QR setup screen.")
                                .font(.system(size: 13))
                                .foregroundStyle(DS.inkFaint)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }

            // Save-success toast
            if vm.saveSuccess {
                VStack {
                    Spacer()
                    Text("Saved")
                        .font(.subheadline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { vm.saveSuccess = false }
                        }
                }
            }
        }
        .overlay {
            // Prompt editor slide-up
            if showPromptEditor && !vm.isLoading {
                SystemPromptEditorView(
                    initialText: vm.systemPrompt,
                    defaultText: vm.defaultPrompt,
                    onSave: { newPrompt in
                        Task {
                            await vm.save(newPrompt)
                            showPromptEditor = false
                        }
                    },
                    onCancel: { showPromptEditor = false }
                )
                .transition(.move(edge: .bottom))
                .zIndex(10)
            }
        }
        .overlay {
            if showHelp {
                HelpView(onDismiss: { showHelp = false })
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: showPromptEditor)
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: showHelp)
        .animation(.easeInOut, value: vm.saveSuccess)
        .task { await vm.load() }
    }

    // ── Section builder ───────────────────────────────────────────────────────
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
    private func settingsRow(
        icon: String,
        label: String,
        chevron: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
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
        .buttonStyle(.plain)
    }
}
