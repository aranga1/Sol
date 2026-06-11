import SwiftUI

struct HomeView: View {
    var onResetConnection: () -> Void = {}

    @State private var daemonVM = DaemonStatusViewModel()
    @State private var showVoiceNote = false
    @State private var showTextNote = false
    @State private var queryText = ""
    @State private var navigateToQuery = false
    @State private var showResetConfirmation = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Two large capture buttons
                HStack(spacing: 24) {
                    CaptureButton(
                        icon: "mic.fill",
                        label: "Voice Note",
                        isEnabled: daemonVM.status == .reachable
                    ) { showVoiceNote = true }

                    CaptureButton(
                        icon: "pencil",
                        label: "Text Note",
                        isEnabled: daemonVM.status == .reachable
                    ) { showTextNote = true }
                }

                Spacer()

                // Query bar
                HStack {
                    TextField("Ask your vault a question…", text: $queryText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { if !queryText.isEmpty { navigateToQuery = true } }
                    Button {
                        if !queryText.isEmpty { navigateToQuery = true }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(queryText.isEmpty || daemonVM.status != .reachable)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Alysha")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    StatusDot(status: daemonVM.status)
                }
            }
            .confirmationDialog(
                "Reset Connection",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Scan a new QR code", role: .destructive) {
                    onResetConnection()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear your current Mac connection and return you to the setup screen.")
            }
            .sheet(isPresented: $showVoiceNote) { VoiceNoteView() }
            .sheet(isPresented: $showTextNote) {
                TextNoteView(onSuccess: {
                    // Could show a toast here in a future issue — dismiss is enough for now
                })
            }
            .navigationDestination(isPresented: $navigateToQuery) {
                QueryView(initialQuestion: queryText)
                    .onDisappear { queryText = "" }
            }
            .onAppear { daemonVM.startPolling() }
            .onDisappear { daemonVM.stopPolling() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { daemonVM.checkNow() }
            }
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
                Image(systemName: icon)
                    .font(.system(size: 44))
                Text(label)
                    .font(.headline)
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
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status {
        case .checking: return .gray
        case .reachable: return .green
        case .unreachable: return .red
        }
    }

    private var label: String {
        switch status {
        case .checking: return "Checking…"
        case .reachable: return "Connected"
        case .unreachable: return "Unreachable"
        }
    }
}
