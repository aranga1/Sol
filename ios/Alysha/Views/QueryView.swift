import SwiftUI

// Renders markdown (bold, italic, code) from a plain string
private func markdownText(_ raw: String) -> Text {
    if let attributed = try? AttributedString(
        markdown: raw,
        options: .init(interpretedSyntax: .inlinesOnly)
    ) {
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
        session = existing  // preserve original id + startedAt — saves update in place
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
            let resp = try await APIClient.shared.query(
                QueryRequest(question: q, history: history.isEmpty ? nil : history)
            )
            pendingQuestion = nil
            let msg = ConversationMessage(question: q, answer: resp.answer, sources: resp.sources)
            messages.append(msg)
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
    @State private var vm: QueryViewModel
    @State private var scrollID: UUID?

    init(initialQuestion: String = "") {
        self.initialQuestion = initialQuestion
        _vm = State(initialValue: QueryViewModel())
    }

    init(session: ConversationSession) {
        self.existingSession = session
        _vm = State(initialValue: QueryViewModel())
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Conversation thread
                    ForEach(vm.messages) { msg in
                        VStack(alignment: .leading, spacing: 12) {
                            // Question bubble
                            HStack {
                                Spacer()
                                Text(msg.question)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.indigo, in: RoundedRectangle(cornerRadius: 16))
                                    .foregroundStyle(.white)
                                    .padding(.leading, 60)
                            }
                            .padding(.horizontal)

                            // Answer + sources
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    markdownText(msg.answer)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                                        .padding(.trailing, 60)
                                    Spacer()
                                }
                                .padding(.horizontal)

                                if !msg.sources.isEmpty {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(msg.sources) { source in
                                            Button { openInObsidian(source) } label: {
                                                HStack {
                                                    Image(systemName: "doc.text")
                                                        .foregroundStyle(.secondary)
                                                        .font(.caption)
                                                    Text(source.title)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                    Spacer()
                                                    Image(systemName: "arrow.up.right")
                                                        .foregroundStyle(.tertiary)
                                                        .font(.caption2)
                                                }
                                                .padding(.horizontal)
                                                .padding(.vertical, 6)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 12)
                        .id(msg.id)
                    }

                    // Pending question bubble (shown immediately on submit)
                    if let pending = vm.pendingQuestion {
                        HStack {
                            Spacer()
                            Text(pending)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(.white)
                                .padding(.leading, 60)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                    }

                    // Loading indicator
                    if vm.isLoading {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView()
                                Text("Thinking…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("30–60 seconds")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                            Spacer()
                        }
                        .id("loading")
                    }

                    // Error
                    if let error = vm.errorMessage {
                        VStack(spacing: 8) {
                            Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal)
                            Button("Retry") {
                                if let last = vm.messages.last {
                                    Task { await vm.ask(last.question) }
                                }
                            }
                        }
                        .padding()
                    }

                    // Empty state
                    if vm.messages.isEmpty && !vm.isLoading {
                        Text("Ask anything about your notes.")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }

                    Color.clear.frame(height: 80)
                }
                .padding(.top)
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
        .safeAreaInset(edge: .bottom) {
            inputBar
        }
        .navigationTitle("Ask Alysha")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let session = existingSession {
                vm.loadSession(session)
            } else if !initialQuestion.isEmpty && vm.messages.isEmpty && !vm.isLoading {
                Task { await vm.ask(initialQuestion) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(vm.messages.isEmpty ? "Ask your vault…" : "Follow up…", text: $vm.followUpText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit { submit() }
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(vm.followUpText.isEmpty || vm.isLoading ? Color.secondary : Color.indigo)
            }
            .disabled(vm.followUpText.isEmpty || vm.isLoading)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func submit() {
        let q = vm.followUpText
        vm.followUpText = ""
        Task { await vm.ask(q) }
    }

    @MainActor
    private func openInObsidian(_ source: SourceItem) {
        let encoded = source.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.file
        guard let url = URL(string: "obsidian://open?vault=Alysha&file=\(encoded)") else { return }
        if UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url) }
    }
}
