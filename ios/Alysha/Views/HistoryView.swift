import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss

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
                            NavigationLink {
                                QueryView(initialHistory: session.messages)
                            } label: {
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
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.delete(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } preview: {
                                ConversationPreview(session: session)
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
        }
    }
}

private struct ConversationPreview: View {
    let session: ConversationSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(session.messages.prefix(3)) { msg in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer()
                            Text(msg.question)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(.white)
                                .padding(.leading, 40)
                        }

                        HStack {
                            Text(msg.answer)
                                .font(.subheadline)
                                .lineLimit(4)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                                .padding(.trailing, 40)
                            Spacer()
                        }
                    }
                }

                if session.messages.count > 3 {
                    Text("+ \(session.messages.count - 3) more message\(session.messages.count - 3 == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding()
        }
        .frame(width: 320)
        .frame(minHeight: 200)
        .background(Color(.systemBackground))
    }
}
