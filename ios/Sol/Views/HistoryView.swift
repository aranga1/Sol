import SwiftUI

private func markdownText(_ raw: String) -> Text {
    if let attributed = try? AttributedString(markdown: raw) {
        return Text(attributed)
    }
    return Text(raw)
}

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared

    var body: some View {
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
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Preview reused from AllChatsView.swift (ConversationPreviewCard)
