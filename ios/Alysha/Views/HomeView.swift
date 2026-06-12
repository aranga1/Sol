import SwiftUI

private let vaultName = "Alysha"
private let drawerFraction: CGFloat = 0.82

// MARK: - Mode enum

enum CaptureMode { case ask, voice, text }

// MARK: - HomeView

struct HomeView: View {
    var onResetConnection: () -> Void = {}

    // Navigation
    @State private var queryText = ""
    @State private var navigateToQuery = false
    @State private var sessionToOpen: ConversationSession? = nil
    @State private var navigateToSession = false
    @State private var navigateToAllChats = false

    // Sheets
    @State private var showSettings = false
    @State private var showVoiceNote = false
    @State private var showTextNote = false
    @State private var showObsidianAlert = false
    @State private var voiceTranscript = ""

    // Drawer
    @State private var drawerOpen = false
    private var drawerWidth: CGFloat { UIScreen.main.bounds.width * drawerFraction }

    // Capture bar
    @State private var barMode: CaptureMode = .ask
    @State private var popOpen = false

    // Background blobs
    @State private var blobPhase: Double = 0

    var body: some View {
        ZStack(alignment: .leading) {
            // Main NavigationStack
            NavigationStack {
                ZStack {
                    // Parchment background
                    DS.parchment.ignoresSafeArea()

                    // Animated background blobs + flowing wave lines
                    blobLayer
                    waveLayer

                    // Main content
                    mainContent

                    // Mode popup (above everything)
                    if popOpen {
                        // Dimmer tap-to-close
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { popOpen = false } }
                            .zIndex(8)

                        ModePopup(barMode: $barMode, popOpen: $popOpen)
                            .zIndex(9)
                    }
                }
                .navigationTitle("")
                .navigationBarHidden(true)
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

            // Dim overlay
            if drawerOpen {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }
                    .transition(.opacity)
                    .zIndex(10)
                    .animation(.easeInOut(duration: 0.28), value: drawerOpen)
            }

            // Drawer
            DrawerView(
                onSelectSession: { session in
                    closeDrawer()
                    sessionToOpen = session
                    navigateToSession = true
                },
                onNewConversation: { closeDrawer() },
                onOpenSettings: { closeDrawer(); showSettings = true },
                onOpenAllChats: { closeDrawer(); navigateToAllChats = true },
                onOpenObsidian: { closeDrawer(); openObsidianVault() }
            )
            .frame(width: drawerWidth)
            .shadow(color: .black.opacity(0.18), radius: 16, x: 6)
            .offset(x: drawerOpen ? 0 : -drawerWidth)
            .animation(.easeInOut(duration: 0.28), value: drawerOpen)
            .zIndex(11)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onResetConnection: onResetConnection)
        }
        .sheet(isPresented: $showVoiceNote) {
            VoiceNoteView(initialTranscript: voiceTranscript)
                .onDisappear { voiceTranscript = "" }
        }
        .sheet(isPresented: $showTextNote) {
            TextNoteView(onSuccess: {})
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
                    if v.translation.width > 60 && v.startLocation.x < 44 { openDrawer() }
                    else if v.translation.width < -60 { closeDrawer() }
                }
        )
        .onAppear {
            // Blob animation timer
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
                blobPhase += 0.016
            }
        }
    }

    // MARK: - Background blobs

    private var blobLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                Circle()
                    .fill(Color(hex: "#C97B5A").opacity(0.13))
                    .frame(width: 280, height: 280)
                    .blur(radius: 10)
                    .offset(
                        x: w * 0.15 + CGFloat(sin(blobPhase * 0.4) * 30),
                        y: h * 0.18 + CGFloat(cos(blobPhase * 0.3) * 20)
                    )

                Circle()
                    .fill(Color(hex: "#8C3322").opacity(0.09))
                    .frame(width: 220, height: 220)
                    .blur(radius: 10)
                    .offset(
                        x: w * 0.72 + CGFloat(cos(blobPhase * 0.35) * 25),
                        y: h * 0.42 + CGFloat(sin(blobPhase * 0.28) * 35)
                    )

                Circle()
                    .fill(Color(hex: "#B5701F").opacity(0.08))
                    .frame(width: 180, height: 180)
                    .blur(radius: 10)
                    .offset(
                        x: w * 0.45 + CGFloat(sin(blobPhase * 0.22) * 40),
                        y: h * 0.72 + CGFloat(cos(blobPhase * 0.45) * 22)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Flowing wave lines
    // TimelineView drives Canvas at display refresh rate — the only reliable way
    // to get continuous Canvas animation in SwiftUI.
    private var waveLayer: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Wave 1 — 34% height, terracotta, scrolls left, period 21 s
                drawWave(ctx: ctx, size: size, t: t,
                         yFraction: 0.34, amplitude: 36, wavelength: 200,
                         color: Color(hex: "#A23E2D").opacity(0.13), lineWidth: 2,
                         period: 21, direction: -1.0)
                // Wave 2 — 52% height, amber, scrolls right, period 28 s
                drawWave(ctx: ctx, size: size, t: t,
                         yFraction: 0.52, amplitude: 46, wavelength: 200,
                         color: Color(hex: "#B5701F").opacity(0.12), lineWidth: 2,
                         period: 28, direction: 1.0)
                // Wave 3 — 67% height, dark terracotta, scrolls left, period 34 s
                drawWave(ctx: ctx, size: size, t: t,
                         yFraction: 0.67, amplitude: 33, wavelength: 200,
                         color: Color(hex: "#8C3322").opacity(0.09), lineWidth: 1.5,
                         period: 34, direction: -1.0)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func drawWave(
        ctx: GraphicsContext, size: CGSize, t: Double,
        yFraction: Double, amplitude: Double, wavelength: Double,
        color: Color, lineWidth: Double,
        period: Double, direction: Double
    ) {
        let centerY = size.height * yFraction
        // How many pixels the wave shifts per second = one full wavelength per `period` seconds
        let pixelOffset = (t / period).truncatingRemainder(dividingBy: 1.0) * wavelength * direction

        var path = Path()
        var x = -wavelength * 2
        var isFirst = true
        while x <= size.width + wavelength {
            let angle = (x - pixelOffset) * .pi * 2 / wavelength
            let pt = CGPoint(x: x, y: centerY + amplitude * sin(angle))
            if isFirst { path.move(to: pt); isFirst = false } else { path.addLine(to: pt) }
            x += 3
        }
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Top bar — matches design padding-top: 60, horizontal: 18
            topBar
                .padding(.top, 60)
                .padding(.horizontal, 18)

            // Title sits immediately below the top bar (margin-top: 26 in design)
            VStack(spacing: 13) {
                Text("Alysha")
                    .font(DS.newsreader(39, weight: .medium))
                    .foregroundStyle(DS.inkDark.opacity(0.62))
                    .tracking(-0.015 * 39)

                Text("How can I help you today?")
                    .font(DS.newsreader(19, weight: .regular, italic: true))
                    .foregroundStyle(DS.inkDark.opacity(0.46))
            }
            .padding(.top, 26)
            .frame(maxWidth: .infinity)

            Spacer()

            // Hint text sits just above the capture bar
            hintText
                .padding(.bottom, 16)

            // Capture bar
            CaptureBar(
                barMode: $barMode,
                popOpen: $popOpen,
                queryText: $queryText,
                navigateToQuery: $navigateToQuery,
                showTextNote: $showTextNote,
                showVoiceNote: $showVoiceNote,
                voiceTranscript: $voiceTranscript
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
                ZStack {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 42, height: 42)
                        .glassBackground(cornerRadius: 21)

                    VStack(spacing: 4.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(DS.inkMid)
                                .frame(width: 18, height: 1.8)
                        }
                    }
                }
                .frame(width: 42, height: 42)
            }

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
            .padding(.horizontal, expanded ? 12 : 0)
            .padding(.vertical, expanded ? 7 : 0)
            .background {
                if expanded {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(DS.glassGradient)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.62), lineWidth: 1)
                        )
                        .shadow(color: Color(hex: "#50321E").opacity(0.32), radius: 16, x: 0, y: 5)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: expanded)
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

// MARK: - Mode Popup

private struct ModePopup: View {
    @Binding var barMode: CaptureMode
    @Binding var popOpen: Bool

    @State private var appeared = false

    private struct ModeOption {
        let mode: CaptureMode
        let icon: String
        let label: String
    }

    private let options: [ModeOption] = [
        ModeOption(mode: .ask, icon: "magnifyingglass", label: "Ask Vault"),
        ModeOption(mode: .voice, icon: "mic.fill", label: "Voice Note"),
        ModeOption(mode: .text, icon: "pencil", label: "Text Note"),
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                // Bottom to top: Ask at top visually (we reverse)
                ForEach(Array(options.reversed().enumerated()), id: \.offset) { idx, option in
                    modeRow(option: option, index: idx)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 30)
            .padding(.bottom, 110)
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private func modeRow(option: ModeOption, index: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { popOpen = false }
            barMode = option.mode
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(DS.terracottaFaint)
                        .frame(width: 30, height: 30)
                    Image(systemName: option.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.terracotta)
                }
                Text(option.label)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(DS.inkDark)
            }
            .padding(.leading, 7)
            .padding(.trailing, 17)
            .padding(.vertical, 7)
            .glassBackground(cornerRadius: 30)
        }
        .buttonStyle(.plain)
        .scaleEffect(appeared ? 1.0 : 0.78)
        .offset(y: appeared ? 0 : 14)
        .animation(
            .spring(response: 0.32, dampingFraction: 0.74)
                .delay(Double(index) * 0.06),
            value: appeared
        )
    }
}

// MARK: - CaptureBar

struct CaptureBar: View {
    @Binding var barMode: CaptureMode
    @Binding var popOpen: Bool
    @Binding var queryText: String
    @Binding var navigateToQuery: Bool
    @Binding var showTextNote: Bool
    @Binding var showVoiceNote: Bool
    @Binding var voiceTranscript: String

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
    }

    // MARK: Left button

    @ViewBuilder
    private var leftButton: some View {
        let isVoiceOrText = barMode == .voice || barMode == .text
        Button {
            // single tap no-op (long press is what matters)
        } label: {
            ZStack {
                Circle()
                    .fill(isVoiceOrText
                          ? Color(hex: "#A23E2D").opacity(0.10)
                          : Color(hex: "#2B2521").opacity(0.10))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle().strokeBorder(
                            isVoiceOrText
                                ? Color(hex: "#A23E2D").opacity(0.30)
                                : Color.clear,
                            lineWidth: 1
                        )
                    )

                Image(systemName: barMode == .voice ? "mic.fill" : (barMode == .text ? "pencil" : "plus"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isVoiceOrText ? DS.terracotta : DS.inkLight)
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                        popOpen = true
                    }
                }
        )
        .buttonStyle(.plain)
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
                        if !queryText.isEmpty { navigateToQuery = true }
                    }

            case .text:
                Button {
                    showTextNote = true
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
                if !queryText.isEmpty { navigateToQuery = true }
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
                showTextNote = true
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
            levels = levels.enumerated().map { i, prev in
                let target = Double.random(in: 0.1...1.0)
                return prev * 0.5 + target * 0.5
            }
        }

        recordTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            recordSeconds += 1
        }
    }

    private func stopRecording() async {
        guard recording else { return }
        levelTimer?.invalidate(); levelTimer = nil
        recordTimer?.invalidate(); recordTimer = nil
        recording = false
        levels = Array(repeating: 0.2, count: 54)

        let transcript = await WhisperService.shared.stopRealtimeRecording()
        voiceTranscript = transcript
        showVoiceNote = true
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

    private let rowHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Alysha")
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
