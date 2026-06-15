import SwiftUI
import UniformTypeIdentifiers

private var vaultName: String { KeychainService.load()?.vaultName ?? "Alysha" }
private let drawerFraction: CGFloat = 0.82

// MARK: - Mode enum

enum CaptureMode: Hashable { case ask, voice, text, upload }

// MARK: - HomeView

struct HomeView: View {
    var onResetConnection: () -> Void = {}

    // Navigation
    @State private var queryText = ""
    @State private var navigateToAllChats = false
    @State private var pendingAllChats = false  // set when overlay must dismiss first

    // Sheets
    @State private var showSettings = false
    @State private var showFeedback = false
    @State private var showObsidianAlert = false

    // Full-screen overlays (slide up)
    @State private var showChat = false
    @State private var chatQuestion = ""
    @State private var chatSession: ConversationSession? = nil
    @State private var showComposer = false
    @State private var composerMode: ComposerMode = .text

    // Drawer
    @State private var drawerOpen = false
    private var drawerWidth: CGFloat { UIScreen.main.bounds.width * drawerFraction }

    // Capture bar
    @State private var barMode: CaptureMode = .ask
    @State private var popOpen = false
    @State private var hoveredMode: CaptureMode? = nil
    @State private var popupItemFrames: [CaptureMode: CGRect] = [:]


    var body: some View {
        ZStack(alignment: .leading) {
            // Main NavigationStack (history / all-chats only — chat + composer are overlays)
            NavigationStack {
                ZStack {
                    DS.parchment.ignoresSafeArea()
                    BreathingBackground()
                    if !showChat && !showComposer { mainContent }

                    if popOpen && !showChat && !showComposer {
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { popOpen = false } }
                            .zIndex(8)
                        ModePopup(barMode: $barMode, popOpen: $popOpen, hoveredMode: $hoveredMode)
                            .zIndex(9)
                    }
                }
                .onPreferenceChange(ModeItemFrameKey.self) { frames in
                    MainActor.assumeIsolated { popupItemFrames = frames }
                }
                .navigationTitle("")
                .navigationBarHidden(true)
                .navigationDestination(isPresented: $navigateToAllChats) {
                    AllChatsView()
                }
            }
            .offset(x: drawerOpen ? drawerWidth : 0)
            .animation(.easeInOut(duration: 0.28), value: drawerOpen)
            .allowsHitTesting(!drawerOpen && !showChat && !showComposer)

            // Dim overlay (drawer)
            if drawerOpen {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }
                    .transition(.opacity)
                    .zIndex(24)  // just below the drawer (25)
                    .animation(.easeInOut(duration: 0.28), value: drawerOpen)
            }

            // Drawer
            DrawerView(
                onSelectSession: { session in
                    closeDrawer()
                    chatSession = session
                    chatQuestion = ""
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showChat = true }
                },
                onNewConversation: { closeDrawer() },
                onOpenSettings: { closeDrawer(); showSettings = true },
                onOpenAllChats: {
                    closeDrawer()
                    if showChat || showComposer {
                        // Dismiss overlay first; onChange fires navigation once gone
                        pendingAllChats = true
                        dismissChat()
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { showComposer = false }
                    } else {
                        navigateToAllChats = true
                    }
                },
                onOpenObsidian: { closeDrawer(); openObsidianVault() },
                onOpenFeedback: { closeDrawer(); showFeedback = true }
            )
            .frame(width: drawerWidth)
            .shadow(color: .black.opacity(0.18), radius: 16, x: 6)
            .offset(x: drawerOpen ? 0 : -drawerWidth)
            .animation(.easeInOut(duration: 0.28), value: drawerOpen)
            .zIndex(25)  // above chat (20) and composer (21) so drawer overlays everything

            // ── Chat overlay (slides up) ───────────────────────────────────
            if showChat {
                Group {
                    if let session = chatSession {
                        QueryView(session: session, onDismiss: dismissChat, onOpenDrawer: openDrawer)
                    } else {
                        QueryView(initialQuestion: chatQuestion, onDismiss: dismissChat, onOpenDrawer: openDrawer)
                    }
                }
                .transition(.move(edge: .bottom))
                .zIndex(20)
            }

            // ── Composer overlay (slides up from bar) ─────────────────────
            if showComposer {
                NoteComposerView(mode: composerMode) {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { showComposer = false }
                }
                .transition(.move(edge: .bottom))
                .zIndex(21)
            }

        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onResetConnection: {
                showSettings = false
                onResetConnection()
            })
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackView()
        }
        .alert("Obsidian Not Installed", isPresented: $showObsidianAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Obsidian is not installed — get it from the App Store.")
        }
        .task { await WhisperService.shared.downloadModelIfNeeded() }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { v in
                    guard !showChat && !showComposer else { return }
                    let sw = UIScreen.main.bounds.width
                    if v.translation.width > 60 && v.startLocation.x < sw * 0.4 { openDrawer() }
                    else if v.translation.width < -60 { closeDrawer() }
                }
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: showChat)
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: showComposer)
        // After an overlay dismisses, fire any pending deferred navigation
        .onChange(of: showChat) { _, showing in
            if !showing && pendingAllChats { pendingAllChats = false; navigateToAllChats = true }
        }
        .onChange(of: showComposer) { _, showing in
            if !showing && pendingAllChats { pendingAllChats = false; navigateToAllChats = true }
        }
        .onAppear { }
    }

    private func dismissChat() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            showChat = false
            chatSession = nil
            chatQuestion = ""
        }
    }

    func openChatForQuery(_ question: String) {
        chatQuestion = question
        chatSession = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showChat = true }
    }

    func openComposer(mode: ComposerMode) {
        composerMode = mode
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { showComposer = true }
    }

    // MARK: - Background blobs


    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Top bar — matches design padding-top: 60, horizontal: 18
            topBar
                .padding(.top, 60)
                .padding(.horizontal, 18)

            // Subtitle — hidden when chat or composer overlay is open
            if !showChat && !showComposer {
                Text("How can I help you today?")
                    .font(DS.newsreader(19, weight: .regular, italic: true))
                    .foregroundStyle(DS.inkDark.opacity(0.46))
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }

            Spacer()

            // Hint text sits just above the capture bar
            hintText
                .padding(.bottom, 16)

            // Capture bar
            CaptureBar(
                barMode: $barMode,
                popOpen: $popOpen,
                hoveredMode: $hoveredMode,
                popupItemFrames: popupItemFrames,
                queryText: $queryText,
                onSendQuery: { q in openChatForQuery(q) },
                onOpenTextComposer: { openComposer(mode: .text) },
                onOpenVoiceComposer: { transcript, duration in
                    openComposer(mode: .voice(transcript: transcript, duration: duration))
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            // Hamburger button
            Button { openDrawer() } label: {
                VStack(spacing: 4.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(DS.inkMid)
                            .frame(width: 18, height: 1.8)
                    }
                }
                .frame(width: 42, height: 42)
                .liquidGlass(shape: Circle(), interactive: true)
            }
            .buttonStyle(.plain)

            Spacer()

            StatusPill()
        }
    }

    // MARK: - Hint text

    private var hintText: some View {
        Group {
            Text("Hold the ")
                .foregroundStyle(DS.inkFaint)
            + Text("+")
                .foregroundStyle(DS.terracotta)
                .fontWeight(.bold)
            + Text(" to switch between asking your vault, a voice note, or a text note.")
                .foregroundStyle(DS.inkFaint)
        }
        .font(.system(size: 14.5))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 252)
    }

    // MARK: - Helpers

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

// MARK: - StatusPill

private struct StatusPill: View {
    @State private var vm = DaemonStatusViewModel()
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Button {
            expanded.toggle()
            if expanded {
                collapseTask?.cancel()
                collapseTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled {
                        withAnimation(.easeOut(duration: 0.2)) { expanded = false }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 11, height: 11)
                    .opacity(vm.status == .checking ? checkingOpacity : 1.0)
                    .animation(
                        vm.status == .checking
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .default,
                        value: vm.status == .checking
                    )

                if expanded {
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DS.inkDark)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
                        .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, expanded ? 12 : 7)
            .padding(.vertical, 7)
            .liquidGlass(shape: Capsule(), interactive: true)
            .animation(.easeInOut(duration: 0.25), value: expanded)
        }
        .buttonStyle(.plain)
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
        .onChange(of: scenePhase) { _, p in if p == .active { vm.checkNow() } }
    }

    @State private var checkingOpacity: Double = 1.0

    private var dotColor: Color {
        switch vm.status {
        case .checking: Color(hex: "#B5701F")
        case .reachable: Color(hex: "#3f7d52")
        case .unreachable: Color(hex: "#C0563D")
        }
    }

    private var label: String {
        switch vm.status {
        case .checking: "Checking\u{2026}"
        case .reachable: "Connected"
        case .unreachable: "Unreachable"
        }
    }
}

// MARK: - Mode item frame preference key

private struct ModeItemFrameKey: PreferenceKey {
    static let defaultValue: [CaptureMode: CGRect] = [:]
    static func reduce(value: inout [CaptureMode: CGRect], nextValue: () -> [CaptureMode: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Mode Popup

private struct ModePopup: View {
    @Binding var barMode: CaptureMode
    @Binding var popOpen: Bool
    @Binding var hoveredMode: CaptureMode?

    @State private var appeared = false

    private struct ModeOption {
        let mode: CaptureMode
        let icon: String
        let label: String
    }

    private let options: [ModeOption] = [
        ModeOption(mode: .ask,    icon: "magnifyingglass",  label: "Ask Vault"),
        ModeOption(mode: .voice,  icon: "mic.fill",          label: "Voice Note"),
        ModeOption(mode: .text,   icon: "pencil",            label: "Text Note"),
        ModeOption(mode: .upload, icon: "arrow.up.doc.fill", label: "Upload File"),
    ]

    var body: some View {
        GeometryReader { _ in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(options.reversed().enumerated()), id: \.offset) { idx, option in
                    modeRow(option: option, index: idx)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 30)
            .padding(.bottom, 110)
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) { appeared = true }
        }
        .onDisappear { hoveredMode = nil }
    }

    @ViewBuilder
    private func modeRow(option: ModeOption, index: Int) -> some View {
        let isHovered = hoveredMode == option.mode

        Button {
            withAnimation(.easeOut(duration: 0.18)) { popOpen = false }
            barMode = option.mode
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isHovered ? DS.terracotta : DS.terracottaFaint)
                        .frame(width: 30, height: 30)
                    Image(systemName: option.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(isHovered ? .white : DS.terracotta)
                }
                Text(option.label)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(DS.inkDark)
            }
            .padding(.leading, 7)
            .padding(.trailing, 17)
            .padding(.vertical, 7)
            .background {
                if isHovered {
                    // Brighter highlight when drag is over this item
                    Capsule().fill(DS.terracotta.opacity(0.18))
                }
            }
            .liquidGlass(shape: Capsule(), interactive: false)
            .scaleEffect(isHovered ? 1.06 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered)
        }
        .buttonStyle(.plain)
        // Report this item's global frame so the drag gesture can hit-test it
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ModeItemFrameKey.self,
                    value: [option.mode: geo.frame(in: .global)]
                )
            }
        )
        .scaleEffect(appeared ? 1.0 : 0.78)
        .offset(y: appeared ? 0 : 14)
        .animation(
            .spring(response: 0.32, dampingFraction: 0.74).delay(Double(index) * 0.06),
            value: appeared
        )
    }
}

// MARK: - CaptureBar

struct CaptureBar: View {
    @Binding var barMode: CaptureMode
    @Binding var popOpen: Bool
    @Binding var hoveredMode: CaptureMode?
    var popupItemFrames: [CaptureMode: CGRect]
    @Binding var queryText: String
    var onSendQuery: (String) -> Void
    var onOpenTextComposer: () -> Void
    var onOpenVoiceComposer: (String, Int) -> Void  // (transcript, durationSeconds)

    // Long-press-then-drag state for the mode button
    @State private var pressTimer: Timer?
    @State private var longPressActive = false

    @State private var showFileImporter = false
    @StateObject private var uploadJob = FileUploadJob()

    @State private var recording = false
    @State private var recordSeconds = 0
    @State private var levels: [Double] = Array(repeating: 0.2, count: 54)
    @State private var levelTimer: Timer?
    @State private var recordTimer: Timer?

    var body: some View {
        HStack(spacing: 9) {
            // Left mode button
            leftButton

            // Middle section
            middleSection

            // Right action button
            rightButton
        }
        .padding(7)
        .glassBackground(cornerRadius: 28)
        .shadow(color: Color(hex: "#50321E").opacity(0.22), radius: 20, x: 0, y: 8)
        .overlay(alignment: .bottom) {
            if uploadJob.phase.isActive {
                UploadProgressBanner(job: uploadJob)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: uploadJob.phase)
    }

    // MARK: Left button

    @ViewBuilder
    private var leftButton: some View {
        let isVoiceOrText = barMode == .voice || barMode == .text || barMode == .upload
        let icon: String = {
            switch barMode {
            case .voice: return "mic.fill"
            case .text: return "pencil"
            case .upload: return "arrow.up.doc.fill"
            default: return "plus"
            }
        }()
        ZStack {
            Circle()
                .fill(isVoiceOrText
                      ? Color(hex: "#A23E2D").opacity(0.10)
                      : Color(hex: "#2B2521").opacity(0.10))
                .frame(width: 40, height: 40)
                .overlay(
                    Circle().strokeBorder(
                        isVoiceOrText ? Color(hex: "#A23E2D").opacity(0.30) : Color.clear,
                        lineWidth: 1
                    )
                )

            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isVoiceOrText ? DS.terracotta : DS.inkLight)
        }
        .frame(width: 40, height: 40)
        .contentShape(Circle())
        // Single continuous DragGesture handles long-press detection AND drag-to-select
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    // Phase 1: start the long-press timer on first touch
                    if pressTimer == nil && !longPressActive {
                        pressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                            MainActor.assumeIsolated {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                                    popOpen = true
                                }
                                longPressActive = true
                            }
                        }
                    }
                    // Phase 2: popup is open — update hover from drag position
                    guard longPressActive else { return }
                    let loc = value.location
                    let newHover = popupItemFrames.first { $0.value.contains(loc) }?.key
                    if newHover != hoveredMode {
                        hoveredMode = newHover          // triggers .sensoryFeedback below
                    }
                }
                .onEnded { _ in
                    pressTimer?.invalidate()
                    pressTimer = nil
                    guard longPressActive else { return }
                    longPressActive = false
                    if let chosen = hoveredMode {
                        barMode = chosen                // triggers .sensoryFeedback below
                        hoveredMode = nil
                        withAnimation(.easeOut(duration: 0.15)) { popOpen = false }
                    }
                }
        )
        // ── Haptics via sensoryFeedback — no-ops gracefully on iPad ──────────
        // Long-press activation: medium impact ("thud" when menu opens)
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: popOpen) { _, new in new }
        // Hover over item: selection tick (same as iOS scroll wheel / picker)
        .sensoryFeedback(.selection, trigger: hoveredMode)
        // Confirm selection: rigid impact (crisp "snap")
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: barMode)
    }

    // MARK: Middle section

    @ViewBuilder
    private var middleSection: some View {
        Group {
            switch barMode {
            case .ask:
                TextField("Ask your vault\u{2026}", text: $queryText)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.inkDark)
                    .tint(DS.terracotta)
                    .submitLabel(.search)
                    .onSubmit {
                        if !queryText.isEmpty { let q = queryText; queryText = ""; onSendQuery(q) }
                    }

            case .text:
                Button {
                    onOpenTextComposer()
                } label: {
                    Text("Write a note\u{2026}")
                        .font(.system(size: 16))
                        .foregroundStyle(DS.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

            case .voice:
                if recording {
                    recordingMiddle
                } else {
                    Text("Hold to record a voice note")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .upload:
                Text("Choose a file to upload\u{2026}")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingMiddle: some View {
        HStack(spacing: 8) {
            // Red pulsing dot
            Circle()
                .fill(Color(hex: "#CE4B2E"))
                .frame(width: 8, height: 8)
                .opacity(recordingDotOpacity)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: recording)

            // Timer
            Text(timerString)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.inkDark)

            // Waveform bars
            HStack(spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, lvl in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DS.terracotta.opacity(0.7))
                        .frame(width: 2, height: max(3, lvl * 22))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @State private var recordingDotOpacity: Double = 1.0

    private var timerString: String {
        let m = recordSeconds / 60
        let s = recordSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Right button

    @ViewBuilder
    private var rightButton: some View {
        switch barMode {
        case .ask:
            Button {
                if !queryText.isEmpty { let q = queryText; queryText = ""; onSendQuery(q) }
            } label: {
                ZStack {
                    Circle()
                        .fill(DS.terracottaGradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(queryText.isEmpty)
            .opacity(queryText.isEmpty ? 0.5 : 1.0)

        case .text:
            Button {
                onOpenTextComposer()
            } label: {
                ZStack {
                    Circle()
                        .fill(DS.terracottaGradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

        case .voice:
            ZStack {
                Circle()
                    .fill(DS.terracottaGradient)
                    .opacity(recording ? 0 : 1)
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(Color(hex: "#CE4B2E"))
                    .opacity(recording ? 1 : 0)
                    .frame(width: 44, height: 44)
                Image(systemName: recording ? "stop.fill" : "waveform")
                    .font(.system(size: recording ? 14 : 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .onLongPressGesture(
                minimumDuration: 0,
                maximumDistance: 60,
                pressing: { pressing in
                    if pressing {
                        startRecording()
                    } else {
                        Task { await stopRecording() }
                    }
                },
                perform: {}
            )

        case .upload:
            Button {
                showFileImporter = true
            } label: {
                ZStack {
                    Circle()
                        .fill(DS.terracottaGradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [
                    UTType.pdf,
                    UTType(filenameExtension: "xlsx") ?? .data,
                    UTType(filenameExtension: "docx") ?? .data
                ],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
    }

    // MARK: Recording logic

    private func startRecording() {
        guard !recording else { return }
        recording = true
        recordSeconds = 0
        recordingDotOpacity = 1.0
        try? WhisperService.shared.startRealtimeRecording()

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            MainActor.assumeIsolated {
                levels = levels.enumerated().map { i, prev in
                    let target = Double.random(in: 0.1...1.0)
                    return prev * 0.5 + target * 0.5
                }
            }
        }

        recordTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                recordSeconds += 1
            }
        }
    }

    private func stopRecording() async {
        guard recording else { return }
        levelTimer?.invalidate(); levelTimer = nil
        recordTimer?.invalidate(); recordTimer = nil
        recording = false
        levels = Array(repeating: 0.2, count: 54)

        let transcript = await WhisperService.shared.stopRealtimeRecording()
        onOpenVoiceComposer(transcript, recordSeconds)
    }

    // MARK: File import handling

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            uploadJob.start(url: url)
        case .failure(let error):
            uploadJob.phase = .failure(message: error.localizedDescription)
        }
    }
}

// MARK: - UploadProgressBanner

private struct UploadProgressBanner: View {
    @ObservedObject var job: FileUploadJob

    var body: some View {
        Group {
            switch job.phase {
            case .idle:
                EmptyView()

            case .reading:
                pill {
                    ProgressView().scaleEffect(0.75).tint(DS.terracotta)
                    Text("Reading file…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.inkDark)
                }

            case .uploading(let progress):
                pill {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Uploading…")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DS.inkDark)
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DS.inkLight)
                                .monospacedDigit()
                        }
                        ProgressView(value: progress)
                            .tint(DS.terracotta)
                            .scaleEffect(x: 1, y: 1.4)
                    }
                }
                .frame(width: 240)

            case .success:
                pill {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.terracotta)
                    Text("Saved to vault")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.inkDark)
                }

            case .failure(let message):
                pill {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.terracottaDark)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upload failed")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DS.inkDark)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.inkLight)
                            .lineLimit(2)
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        Button("Retry") { job.retry() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.terracotta)
                        Button("Dismiss") { job.dismiss() }
                            .font(.system(size: 12))
                            .foregroundStyle(DS.inkLight)
                    }
                }
                .frame(width: 300)
            }
        }
    }

    @ViewBuilder
    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlass(shape: Capsule())
        .shadow(color: Color(hex: "#50321E").opacity(0.16), radius: 16, x: 0, y: 6)
    }
}

// MARK: - DrawerView

private struct DrawerView: View {
    @ObservedObject private var store = HistoryStore.shared
    let onSelectSession: (ConversationSession) -> Void
    let onNewConversation: () -> Void
    let onOpenSettings: () -> Void
    let onOpenAllChats: () -> Void
    let onOpenObsidian: () -> Void
    let onOpenFeedback: () -> Void

    private let rowHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Sol")
                .font(DS.newsreader(34))
                .foregroundStyle(Color(hex: "#F3ECDD"))
                .padding(.horizontal, 22)
                .padding(.top, 62)
                .padding(.bottom, 22)

            // New conversation button
            Button(action: onNewConversation) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .foregroundStyle(.white)
                    Text("New conversation")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(DS.terracottaGradient, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: DS.terracotta.opacity(0.45), radius: 12, x: 0, y: 4)
            }
            .padding(.horizontal, 16)

            // Hairline divider
            Rectangle()
                .fill(Color(hex: "#EDE4D3").opacity(0.12))
                .frame(height: 1)
                .padding(.top, 20)

            // RECENTS label
            Text("RECENTS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.inkWarm)
                .tracking(1.1)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 10)

            // Session list
            if store.sessions.isEmpty {
                Text("No conversations yet")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#E7DDCA").opacity(0.46))
                    .padding(.horizontal, 22)
                Spacer()
            } else {
                GeometryReader { geo in
                    let maxFit = max(2, Int(geo.size.height / rowHeight))
                    let visibleCount = min(store.sessions.count, maxFit - 1)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.sessions.prefix(visibleCount))) { session in
                            Button {
                                onSelectSession(session)
                            } label: {
                                Text(session.title)
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(Color(hex: "#E7DDCA"))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 12)
                            }
                            Rectangle()
                                .fill(Color(hex: "#EDE4D3").opacity(0.09))
                                .frame(height: 1)
                        }

                        // All chats row
                        Button(action: onOpenAllChats) {
                            HStack {
                                Text("All chats")
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(Color(hex: "#EDE4D3").opacity(0.62))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color(hex: "#EDE4D3").opacity(0.46))
                            }
                            .padding(.horizontal, 22)
                            .frame(height: rowHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Spacer()
                    }
                }
            }

            // Footer hairline
            Rectangle()
                .fill(Color(hex: "#EDE4D3").opacity(0.12))
                .frame(height: 1)

            // Open in Obsidian
            Button(action: onOpenObsidian) {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .foregroundStyle(Color(hex: "#CBB994"))
                        .frame(width: 20)
                    Text("Open in Obsidian")
                        .font(.body)
                        .foregroundStyle(Color(hex: "#E7DDCA"))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Feedback
            Button(action: onOpenFeedback) {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .foregroundStyle(Color(hex: "#CBB994"))
                        .frame(width: 20)
                    Text("Feedback")
                        .font(.body)
                        .foregroundStyle(Color(hex: "#E7DDCA"))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Settings
            Button(action: onOpenSettings) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color(hex: "#CBB994"))
                        .frame(width: 20)
                    Text("Settings")
                        .font(.body)
                        .foregroundStyle(Color(hex: "#E7DDCA"))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
        }
        .background(DS.espresso)
        .ignoresSafeArea()
    }
}
