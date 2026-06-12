import SwiftUI

// Renders markdown (bold, italic, code) from a plain string
private func markdownText(_ raw: String) -> Text {
    if let attributed = try? AttributedString(markdown: raw) {
        return Text(attributed)
    }
    return Text(raw)
}

@Observable
@MainActor
private final class QueryViewModel {
    var messages: [ConversationMessage] = []
    var pendingQuestion: String? = nil
    var isLoading = false
    var errorMessage: String?
    var followUpText = ""

    private var session: ConversationSession?

    func loadSession(_ existing: ConversationSession) {
        messages = existing.messages
        session = existing
    }

    func ask(_ q: String) async {
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoading = true
        errorMessage = nil
        pendingQuestion = q

        let history = messages.flatMap { msg in [
            HistoryMessage(role: "user", content: msg.question),
            HistoryMessage(role: "assistant", content: msg.answer)
        ]}

        do {
            let (bytes, response) = try await APIClient.shared.queryStream(
                QueryRequest(question: q, history: history.isEmpty ? nil : history)
            )
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw SolAPIError.httpError(
                    statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
                )
            }

            // Add placeholder bubble immediately so the user sees activity
            pendingQuestion = nil
            let msgID = UUID()
            messages.append(ConversationMessage(id: msgID, question: q, answer: "", sources: []))

            var accumulated = ""
            var sources: [SourceItem] = []

            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(SSEEvent.self, from: data)
                else { continue }

                switch event.type {
                case "token":
                    accumulated += event.content ?? ""
                    if let idx = messages.indices.last {
                        messages[idx] = ConversationMessage(
                            id: msgID, question: q,
                            answer: accumulated, sources: sources
                        )
                    }
                case "sources":
                    sources = event.sources ?? []
                    if let idx = messages.indices.last {
                        messages[idx] = ConversationMessage(
                            id: msgID, question: q,
                            answer: accumulated, sources: sources
                        )
                    }
                case "error":
                    errorMessage = event.content ?? "Unknown error"
                    messages.removeLast()
                case "done":
                    break
                default:
                    break
                }
            }

            persistSession()
        } catch {
            pendingQuestion = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func persistSession() {
        if session == nil {
            session = ConversationSession(id: UUID(), startedAt: Date(), messages: messages)
        } else {
            session!.messages = messages
        }
        HistoryStore.shared.save(session!)
    }
}

struct QueryView: View {
    var initialQuestion: String = ""
    var existingSession: ConversationSession? = nil
    var onDismiss: (() -> Void)? = nil
    var onOpenDrawer: (() -> Void)? = nil  // overlay mode: open home drawer
    @State private var vm: QueryViewModel
    @State private var scrollID: UUID?
    @State private var thinkPhase = false
    @Environment(\.dismiss) private var dismiss

    init(initialQuestion: String = "", onDismiss: (() -> Void)? = nil, onOpenDrawer: (() -> Void)? = nil) {
        self.initialQuestion = initialQuestion
        self.onDismiss = onDismiss
        self.onOpenDrawer = onOpenDrawer
        _vm = State(initialValue: QueryViewModel())
    }

    init(session: ConversationSession, onDismiss: (() -> Void)? = nil, onOpenDrawer: (() -> Void)? = nil) {
        self.existingSession = session
        self.onDismiss = onDismiss
        self.onOpenDrawer = onOpenDrawer
        _vm = State(initialValue: QueryViewModel())
    }

    private func goBack() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    var body: some View {
        ZStack {
            DS.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                // Overlay mode: show manual top bar (no NavigationStack wrapping us)
                if onDismiss != nil { overlayTopBar }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {

                            // Conversation thread
                            ForEach(vm.messages) { msg in
                                VStack(alignment: .leading, spacing: 0) {
                                    // User bubble
                                    userBubble(msg.question)
                                        .padding(.bottom, 14)

                                    // Assistant message
                                    assistantMessage(msg)
                                }
                                .padding(.vertical, 12)
                                .id(msg.id)
                            }

                            // Pending question bubble
                            if let pending = vm.pendingQuestion {
                                userBubble(pending)
                                    .padding(.vertical, 12)
                            }

                            // Thinking indicator
                            if vm.isLoading {
                                thinkingIndicator
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 16)
                                    .id("loading")
                            }

                            // Error
                            if let error = vm.errorMessage {
                                VStack(spacing: 8) {
                                    Text(error)
                                        .foregroundStyle(DS.terracotta)
                                        .font(.caption)
                                        .padding(.horizontal, 20)
                                    Button("Retry") {
                                        if let last = vm.messages.last {
                                            Task { await vm.ask(last.question) }
                                        }
                                    }
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(DS.terracottaDark)
                                }
                                .padding(.vertical, 12)
                            }

                            // Empty state
                            if vm.messages.isEmpty && !vm.isLoading && vm.pendingQuestion == nil {
                                Text("Ask anything about your notes.")
                                    .foregroundStyle(DS.inkFaint)
                                    .font(.system(size: 16))
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                            }

                            Color.clear.frame(height: 20)
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: vm.messages.count) { _, _ in
                        withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                    }
                    .onChange(of: vm.isLoading) { _, loading in
                        if loading { withAnimation { proxy.scrollTo("loading", anchor: .bottom) } }
                    }
                    .onChange(of: vm.pendingQuestion) { _, q in
                        if q != nil { withAnimation { proxy.scrollTo("loading", anchor: .bottom) } }
                    }
                }

                // Bottom input bar
                queryInputBar
            }
        }
        .navigationTitle("Ask Sol")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DS.parchment, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar {
            // Principal title only — system back button handles navigation inside NavigationStack.
            // Overlay mode gets its own overlayTopBar with X + hamburger.
            ToolbarItem(placement: .principal) {
                Text("Ask Sol")
                    .font(DS.newsreader(20, weight: .medium))
                    .foregroundStyle(DS.inkDark)
            }
        }
        .navigationBarBackButtonHidden(onDismiss != nil)
        // Swipe right from left 40% of screen → open drawer (overlay mode)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { v in
                    let sw = UIScreen.main.bounds.width
                    if v.translation.width > 60 && v.startLocation.x < sw * 0.4 {
                        onOpenDrawer?()
                    }
                }
        )
        .onAppear {
            if let session = existingSession {
                vm.loadSession(session)
            } else if !initialQuestion.isEmpty && vm.messages.isEmpty && !vm.isLoading {
                Task { await vm.ask(initialQuestion) }
            }
        }
    }

    // MARK: - Overlay top bar (shown when presented as full-screen overlay, not via NavigationLink)

    private var overlayTopBar: some View {
        HStack(spacing: 0) {
            // Hamburger — opens home drawer while staying in chat
            Button { onOpenDrawer?() } label: {
                VStack(spacing: 4.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(DS.inkMid)
                            .frame(width: 18, height: 1.8)
                    }
                }
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Ask Sol")
                .font(DS.newsreader(20, weight: .medium))
                .foregroundStyle(DS.inkDark)

            Spacer()

            // X to dismiss chat
            Button(action: goBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.inkMid)
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 54)
        .padding(.bottom, 10)
        .background(DS.parchment)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - User bubble

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "#FDF3EE"))
                .lineSpacing(0.52 * 16 * 0.4)
                .padding(.vertical, 11)
                .padding(.horizontal, 16)
                .background(
                    DS.terracottaGradient,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 21,
                        bottomLeadingRadius: 21,
                        bottomTrailingRadius: 7,
                        topTrailingRadius: 21
                    )
                )
                .shadow(
                    color: Color(hex: "#78281C").opacity(0.30),
                    radius: 5,
                    x: 0,
                    y: 2
                )
        }
    }

    // MARK: - Assistant message

    private func assistantMessage(_ msg: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // "A" avatar
                ZStack {
                    Circle()
                        .fill(DS.terracottaGradient)
                        .frame(width: 30, height: 30)
                    Text("A")
                        .font(DS.newsreader(16, weight: .semibold))
                        .foregroundStyle(.white)
                }

                // Answer card
                VStack(alignment: .leading, spacing: 0) {
                    markdownText(msg.answer)
                        .font(.system(size: 16))
                        .foregroundStyle(DS.inkDark)
                        .lineSpacing(16 * 0.52 * 0.4)
                        .textSelection(.enabled)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(
                    DS.parchmentCard,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 7,
                        bottomLeadingRadius: 21,
                        bottomTrailingRadius: 21,
                        topTrailingRadius: 21
                    )
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 7,
                        bottomLeadingRadius: 21,
                        bottomTrailingRadius: 21,
                        topTrailingRadius: 21
                    )
                    .strokeBorder(DS.inkDark.opacity(0.07), lineWidth: 1)
                )

                Spacer(minLength: 40)
            }

            // Source chips
            if !msg.sources.isEmpty {
                sourceChips(msg.sources)
                    .padding(.leading, 40)
            }
        }
    }

    // MARK: - Source scroll

    private func sourceChips(_ sources: [SourceItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(DS.inkFaint)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sources) { source in
                        Button { openInObsidian(source) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(DS.terracotta)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(DS.inkDark)
                                        .lineLimit(1)
                                    Text("Open in Obsidian")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DS.inkFaint)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: 200, alignment: .leading)
                            .background(DS.parchmentCard, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(DS.terracotta.opacity(0.18), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Thinking indicator

    private var thinkingIndicator: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(DS.terracottaGradient)
                    .frame(width: 30, height: 30)
                Text("A")
                    .font(DS.newsreader(16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color(hex: "#B08968"))
                        .frame(width: 7, height: 7)
                        .opacity(thinkPhase ? 0.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(i) * 0.2),
                            value: thinkPhase
                        )
                }
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(
                DS.parchmentCard,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 7,
                    bottomLeadingRadius: 21,
                    bottomTrailingRadius: 21,
                    topTrailingRadius: 21
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 7,
                    bottomLeadingRadius: 21,
                    bottomTrailingRadius: 21,
                    topTrailingRadius: 21
                )
                .strokeBorder(DS.inkDark.opacity(0.07), lineWidth: 1)
            )
            .onAppear { thinkPhase = true }

            Spacer()
        }
    }

    // MARK: - Bottom input bar

    private var queryInputBar: some View {
        HStack(spacing: 9) {
            TextField("Ask a follow-up\u{2026}", text: $vm.followUpText)
                .font(.system(size: 16))
                .foregroundStyle(DS.inkDark)
                .tint(DS.terracotta)
                .submitLabel(.send)
                .onSubmit { submit() }
                .padding(.leading, 17)
                .padding(.trailing, 4)

            Button(action: submit) {
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
            .disabled(vm.followUpText.isEmpty || vm.isLoading)
            .opacity(vm.followUpText.isEmpty || vm.isLoading ? 0.5 : 1.0)
            .padding(.trailing, 1)
        }
        .padding(.vertical, 7)
        .padding(.leading, 0)
        .glassBackground(cornerRadius: 28)
        .shadow(color: Color(hex: "#50321E").opacity(0.18), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 8)
        .background(DS.parchment)
    }

    private func submit() {
        let q = vm.followUpText
        vm.followUpText = ""
        Task { await vm.ask(q) }
    }

    @MainActor
    private func openInObsidian(_ source: SourceItem) {
        let encoded = source.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.file
        guard let url = URL(string: "obsidian://open?vault=Sol&file=\(encoded)") else { return }
        if UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url) }
    }
}

// MARK: - FlowLayout helper (horizontal wrapping)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? UIScreen.main.bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + spacing
                totalHeight = y
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
