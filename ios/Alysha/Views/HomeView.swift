import SwiftUI

private let vaultName = "Alysha"
private let drawerFraction: CGFloat = 0.82

struct HomeView: View {
    var onResetConnection: () -> Void = {}

    // Navigation
    @State private var isConnected = false
    @State private var queryText = ""
    @State private var navigateToQuery = false
    @State private var sessionToOpen: ConversationSession? = nil
    @State private var navigateToSession = false
    @State private var showVoiceNote = false
    @State private var showTextNote = false
    @State private var showObsidianAlert = false

    // Drawer + Settings
    @State private var drawerOpen = false
    @State private var showSettings = false
    @State private var navigateToAllChats = false

    private var drawerWidth: CGFloat { UIScreen.main.bounds.width * drawerFraction }

    var body: some View {
        ZStack(alignment: .leading) {
            // ── Main stack ─────────────────────────────────────────────────────
            NavigationStack {
                mainContent
                    .navigationTitle("Alysha")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbarItems }
                    .navigationDestination(isPresented: $navigateToQuery) {
                        QueryView(initialQuestion: queryText).onDisappear { queryText = "" }
                    }
                    .navigationDestination(isPresented: $navigateToSession) {
                        if let s = sessionToOpen {
                            QueryView(session: s).onDisappear { sessionToOpen = nil }
                        }
                    }
                    .navigationDestination(isPresented: $navigateToAllChats) {
                        AllChatsView()
                    }
            }
            .offset(x: drawerOpen ? drawerWidth : 0)
            .animation(.easeInOut(duration: 0.28), value: drawerOpen)
            .allowsHitTesting(!drawerOpen)

            // ── Dim overlay ───────────────────────────────────────────────────
            if drawerOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }
                    .transition(.opacity)
                    .zIndex(1)
                    .animation(.easeInOut(duration: 0.28), value: drawerOpen)
            }

            // ── Drawer ────────────────────────────────────────────────────────
            DrawerView(
                onSelectSession: { session in
                    closeDrawer()
                    sessionToOpen = session
                    navigateToSession = true
                },
                onNewConversation: { closeDrawer() },
                onOpenSettings: { closeDrawer(); showSettings = true },
                onOpenAllChats: { closeDrawer(); navigateToAllChats = true }
            )
            .frame(width: drawerWidth)
            .shadow(color: .black.opacity(0.15), radius: 12, x: 4)
            .offset(x: drawerOpen ? 0 : -drawerWidth)
            .animation(.easeInOut(duration: 0.28), value: drawerOpen)
            .zIndex(2)
        }
        // Sheets
        .sheet(isPresented: $showSettings) {
            SettingsView(onResetConnection: onResetConnection)
        }
        .sheet(isPresented: $showVoiceNote) { VoiceNoteView() }
        .sheet(isPresented: $showTextNote) { TextNoteView(onSuccess: {}) }
        .alert("Obsidian Not Installed", isPresented: $showObsidianAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Obsidian is not installed — get it from the App Store.")
        }
        .task { await WhisperService.shared.downloadModelIfNeeded() }
        // Swipe-right-from-edge to open drawer
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { v in
                    if v.translation.width > 60 && v.startLocation.x < 44 { openDrawer() }
                    else if v.translation.width < -60 { closeDrawer() }
                }
        )
    }

    // ── Main content ───────────────────────────────────────────────────────────
    private var mainContent: some View {
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

            Button { openObsidianVault() } label: {
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
    }

    // ── Toolbar ────────────────────────────────────────────────────────────────
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { openDrawer() } label: {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.primary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            DaemonStatusIndicator { isConnected = $0 }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    private func openDrawer() { withAnimation { drawerOpen = true } }
    private func closeDrawer() { withAnimation { drawerOpen = false } }

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

// ── Drawer ─────────────────────────────────────────────────────────────────────
private struct DrawerView: View {
    @ObservedObject private var store = HistoryStore.shared
    let onSelectSession: (ConversationSession) -> Void
    let onNewConversation: () -> Void
    let onOpenSettings: () -> Void
    let onOpenAllChats: () -> Void

    private let rowHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Alysha")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 64)
            .padding(.bottom, 20)

            // New conversation button
            Button(action: onNewConversation) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                    Text("New conversation")
                        .font(.subheadline)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
            }

            Divider().padding(.vertical, 16)

            // Recents label
            Text("Recents")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            if store.sessions.isEmpty {
                Text("No conversations yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                Spacer()
            } else {
                // GeometryReader fills the space between the label and footer.
                // We use it to count how many rows actually fit.
                GeometryReader { geo in
                    let maxFit = max(1, Int(geo.size.height / rowHeight))
                    let needsAllChats = store.sessions.count > maxFit
                    // Reserve one row for "All chats" button when needed
                    let visibleCount = needsAllChats ? maxFit - 1 : min(store.sessions.count, maxFit)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.sessions.prefix(visibleCount))) { session in
                            Button {
                                onSelectSession(session)
                            } label: {
                                Text(session.title)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .frame(height: rowHeight)
                            }
                            Divider().padding(.horizontal, 20)
                        }

                        if needsAllChats {
                            Button(action: onOpenAllChats) {
                                HStack {
                                    Text("All chats")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 20)
                                .frame(height: rowHeight)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        Spacer()
                    }
                }
            }

            Divider()

            // Settings
            Button(action: onOpenSettings) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape").frame(width: 20)
                    Text("Settings").font(.body)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
        .ignoresSafeArea()
    }
}

// ── Shared subviews ────────────────────────────────────────────────────────────
private struct DaemonStatusIndicator: View {
    let onStatusChange: (Bool) -> Void
    @State private var vm = DaemonStatusViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        StatusDot(status: vm.status)
            .onAppear { vm.startPolling() }
            .onDisappear { vm.stopPolling() }
            .onChange(of: vm.status) { _, s in onStatusChange(s == .reachable) }
            .onChange(of: scenePhase) { _, p in if p == .active { vm.checkNow() } }
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
            Circle().fill(dotColor).frame(width: 10, height: 10)
            Text(label).font(.caption).foregroundStyle(.secondary)
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
