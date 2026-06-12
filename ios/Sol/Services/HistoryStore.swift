import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var sessions: [ConversationSession] = []

    private let dir: URL
    private let maxSessions = 100
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        sessions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ConversationSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ConversationSession.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ session: ConversationSession) {
        let url = dir.appendingPathComponent("\(session.id.uuidString).json")
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: url, options: .atomic)

        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.insert(session, at: 0)
            pruneIfNeeded()
        }
    }

    func delete(_ session: ConversationSession) {
        let url = dir.appendingPathComponent("\(session.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        sessions.removeAll { $0.id == session.id }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            delete(sessions[index])
        }
    }

    private func pruneIfNeeded() {
        guard sessions.count > maxSessions else { return }
        let toRemove = sessions.suffix(from: maxSessions)
        for session in toRemove { delete(session) }
    }
}
