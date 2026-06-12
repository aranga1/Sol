import SwiftUI

struct AllChatsView: View {
    @ObservedObject private var store = HistoryStore.shared

    // MARK: - Grouping

    private var today: [ConversationSession] {
        let cal = Calendar.current
        return store.sessions.filter { cal.isDateInToday($0.startedAt) }
    }

    private var thisWeek: [ConversationSession] {
        let cal = Calendar.current
        return store.sessions.filter {
            !cal.isDateInToday($0.startedAt) && cal.isDate($0.startedAt, equalTo: Date(), toGranularity: .weekOfYear)
        }
    }

    private var earlier: [ConversationSession] {
        let cal = Calendar.current
        return store.sessions.filter {
            !cal.isDate($0.startedAt, equalTo: Date(), toGranularity: .weekOfYear)
        }
    }

    var body: some View {
        ZStack {
            DS.parchment.ignoresSafeArea()

            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "No conversations yet",
                    systemImage: "clock",
                    description: Text("Past conversations will appear here.")
                )
                .foregroundStyle(DS.inkFaint)
            } else {
                List {
                    if !today.isEmpty {
                        sessionSection(title: "TODAY", sessions: today)
                    }
                    if !thisWeek.isEmpty {
                        sessionSection(title: "THIS WEEK", sessions: thisWeek)
                    }
                    if !earlier.isEmpty {
                        sessionSection(title: "EARLIER", sessions: earlier)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("All Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DS.parchment, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("All Chats")
                    .font(DS.newsreader(20, weight: .medium))
                    .foregroundStyle(DS.inkDark)
            }
        }
    }

    // MARK: - Section

    @ViewBuilder
    private func sessionSection(title: String, sessions: [ConversationSession]) -> some View {
        Section {
            ForEach(sessions) { session in
                NavigationLink {
                    QueryView(session: session)
                } label: {
                    sessionCard(session)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
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
        } header: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DS.inkFaint)
                .kerning(0.18 * 11)
                .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 6, trailing: 16))
        }
    }

    // MARK: - Session card

    private func sessionCard(_ session: ConversationSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(session.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.inkDark)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                let count = session.messages.count
                Text("\(count) message\(count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.terracottaDark)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(DS.terracotta.opacity(0.08), in: Capsule())

                Spacer()

                Text(session.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.inkFaint)
            }
            .padding(.top, 11)
        }
        .padding(16)
        .background(DS.parchmentCard, in: RoundedRectangle(cornerRadius: DS.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .strokeBorder(DS.inkDark.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: Color(hex: "#50321E").opacity(0.30), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Conversation preview card (context menu)

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
                            .background(DS.terracottaGradient, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(Color(hex: "#FDF3EE"))
                    }
                    HStack {
                        Text(msg.answer)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(DS.parchmentCard, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(DS.inkDark)
                        Spacer(minLength: 32)
                    }
                }
            }
            if session.messages.count > 3 {
                Text("+ \(session.messages.count - 3) more\u{2026}")
                    .font(.caption2)
                    .foregroundStyle(DS.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 340)
        .background(DS.parchment)
    }
}
