import SwiftUI

@Observable
@MainActor
private final class QueryViewModel {
    var question: String
    var answer: String?
    var sources: [SourceItem] = []
    var isLoading = false
    var errorMessage: String?
    var followUpText = ""

    init(question: String) { self.question = question }

    func ask(_ q: String) async {
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        question = q
        isLoading = true
        answer = nil
        sources = []
        errorMessage = nil
        do {
            let resp = try await APIClient.shared.query(QueryRequest(question: q))
            answer = resp.answer
            sources = resp.sources
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct QueryView: View {
    var initialQuestion: String = ""
    @State private var vm: QueryViewModel

    init(initialQuestion: String = "") {
        self.initialQuestion = initialQuestion
        _vm = State(initialValue: QueryViewModel(question: initialQuestion))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Question header
                if !vm.question.isEmpty {
                    Text(vm.question)
                        .font(.headline)
                        .padding(.horizontal)
                }

                // Loading / answer / error
                if vm.isLoading {
                    ProgressView("Searching your vault…")
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if let answer = vm.answer {
                    Text(answer)
                        .padding(.horizontal)
                        .textSelection(.enabled)

                    if !vm.sources.isEmpty {
                        Divider().padding(.horizontal)

                        Text("Sources")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        ForEach(vm.sources) { source in
                            Button {
                                openInObsidian(source)
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    Text(source.title)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .foregroundStyle(.tertiary)
                                        .font(.caption)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                } else if let error = vm.errorMessage {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.red).padding(.horizontal)
                        Button("Retry") { Task { await vm.ask(vm.question) } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }

                Divider().padding(.horizontal)

                // Follow-up question bar
                HStack {
                    TextField("Ask a follow-up…", text: $vm.followUpText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { submitFollowUp() }
                    Button(action: submitFollowUp) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(vm.followUpText.isEmpty || vm.isLoading)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .padding(.top)
        }
        .navigationTitle("Ask Alysha")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !initialQuestion.isEmpty && vm.answer == nil && !vm.isLoading {
                Task { await vm.ask(initialQuestion) }
            }
        }
    }

    private func submitFollowUp() {
        let q = vm.followUpText
        vm.followUpText = ""
        Task { await vm.ask(q) }
    }

    private func openInObsidian(_ source: SourceItem) {
        let encoded = source.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.file
        guard let url = URL(string: "obsidian://open?vault=Alysha&file=\(encoded)") else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            // Obsidian not installed — show a brief note (handled via vm in a follow-up)
        }
    }
}
