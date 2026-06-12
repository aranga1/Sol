import SwiftUI

struct AllChatsView: View {
    @ObservedObject private var store = HistoryStore.shared

    var body: some View {
        List {
            ForEach(store.sessions) { session in
                NavigationLink {
                    QueryView(session: session)
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
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        store.delete(session)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        store.delete(session)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } preview: {
                    ConversationPreviewCard(session: session)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("All Chats")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "No conversations yet",
                    systemImage: "clock",
                    description: Text("Past conversations will appear here.")
                )
            }
        }
    }
}

// Shared preview card — same bubble style used in HistoryView
struct ConversationPreviewCard: View {
    let session: ConversationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(session.messages.prefix(3)) { msg in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer(minLength: 32)
                        Text(msg.question)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    HStack {
                        Text(msg.answer)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        Spacer(minLength: 32)
                    }
                }
            }
            if session.messages.count > 3 {
                Text("+ \(session.messages.count - 3) more…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 340)
        .background(Color(.systemBackground))
    }
}
