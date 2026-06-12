import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSession: ConversationSession?
    @State private var continueSession: ConversationSession?

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock",
                        description: Text("Past conversations will appear here.")
                    )
                } else {
                    List {
                        ForEach(store.sessions) { session in
                            Button { selectedSession = session } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    HStack {
                                        Text("\(session.messages.count) message\(session.messages.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedSession) { session in
                SessionDetailView(session: session, onContinue: {
                    continueSession = session
                    selectedSession = nil
                })
            }
            .navigationDestination(item: $continueSession) { session in
                QueryView(initialHistory: session.messages)
                    .onAppear { dismiss() }
            }
        }
    }
}

private struct SessionDetailView: View {
    let session: ConversationSession
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.messages) { msg in
                        VStack(alignment: .leading, spacing: 12) {
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

                            HStack {
                                Text(msg.answer)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                                    .padding(.trailing, 60)
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical, 12)
                    }
                    Color.clear.frame(height: 80)
                }
                .padding(.top)
            }
            .navigationTitle(session.startedAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { onContinue() }
                        .bold()
                }
            }
        }
    }
}
