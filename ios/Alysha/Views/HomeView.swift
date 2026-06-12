import SwiftUI

private let vaultName = "Alysha"

struct HomeView: View {
    var onResetConnection: () -> Void = {}

    @State private var isConnected = false
    @State private var showVoiceNote = false
    @State private var showTextNote = false
    @State private var queryText = ""
    @State private var navigateToQuery = false
    @State private var showSettings = false
    @State private var showObsidianAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                HStack(spacing: 24) {
                    CaptureButton(icon: "mic.fill", label: "Voice Note", isEnabled: isConnected) {
                        showVoiceNote = true
                    }
                    CaptureButton(icon: "pencil", label: "Text Note", isEnabled: isConnected) {
                        showTextNote = true
                    }
                }

                Button {
                    openObsidianVault()
                } label: {
                    Label("Open in Obsidian", systemImage: "book.closed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack {
                    TextField("Ask your vault a question…", text: $queryText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { if !queryText.isEmpty { navigateToQuery = true } }
                    Button {
                        if !queryText.isEmpty { navigateToQuery = true }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(queryText.isEmpty || !isConnected)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Alysha")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Owns its own VM — only this view re-renders on status changes
                    DaemonStatusIndicator { isConnected = $0 }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(onResetConnection: onResetConnection)
            }
            .sheet(isPresented: $showVoiceNote) { VoiceNoteView() }
            .sheet(isPresented: $showTextNote) { TextNoteView(onSuccess: {}) }
            .navigationDestination(isPresented: $navigateToQuery) {
                QueryView(initialQuestion: queryText).onDisappear { queryText = "" }
            }
            .alert("Obsidian Not Installed", isPresented: $showObsidianAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Obsidian is not installed — get it from the App Store.")
            }
        }
    }

    @MainActor
    private func openObsidianVault() {
        let encoded = vaultName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? vaultName
        guard let url = URL(string: "obsidian://open?vault=\(encoded)"),
              UIApplication.shared.canOpenURL(url) else {
            showObsidianAlert = true
            return
        }
        UIApplication.shared.open(url)
    }
}

// Isolated status view — owns DaemonStatusViewModel so only this subtree re-renders on polls
private struct DaemonStatusIndicator: View {
    let onStatusChange: (Bool) -> Void

    @State private var vm = DaemonStatusViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        StatusDot(status: vm.status)
            .onAppear { vm.startPolling() }
            .onDisappear { vm.stopPolling() }
            .onChange(of: vm.status) { _, newStatus in
                onStatusChange(newStatus == .reachable)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { vm.checkNow() }
            }
    }
}

private struct CaptureButton: View {
    let icon: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 44))
                Text(label).font(.headline)
            }
            .frame(width: 140, height: 140)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.4)
    }
}

private struct StatusDot: View {
    let status: DaemonStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        switch status {
        case .checking: .gray
        case .reachable: .green
        case .unreachable: .red
        }
    }

    private var label: String {
        switch status {
        case .checking: "Checking…"
        case .reachable: "Connected"
        case .unreachable: "Unreachable"
        }
    }
}
