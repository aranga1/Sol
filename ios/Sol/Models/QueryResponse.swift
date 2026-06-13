import Foundation

struct HistoryMessage: Codable {
    let role: String   // "user" | "assistant"
    let content: String
}

struct QueryRequest: Codable {
    let question: String
    let history: [HistoryMessage]?
}

struct SourceItem: Codable, Identifiable, Hashable {
    let file: String
    let title: String
    var id: String { file }
}

// SSE event emitted by /api/query stream
struct SSEEvent: Decodable {
    let type: String           // "token" | "sources" | "done" | "error" | "action"
    let content: String?       // present for type=token and type=error
    let sources: [SourceItem]? // present for type=sources
    let action: String?        // present for type=action
}

struct CreateEventPayload: Decodable, Equatable {
    let title: String
    let start: Date
    let durationMinutes: Int
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title, start, notes
        case durationMinutes = "duration_minutes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? "New Event"
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)

        let startString = try container.decode(String.self, forKey: .start)
        // Try multiple formats: LLM may omit timezone (e.g. "2026-06-14T12:00:00")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: startString) {
            start = date
        } else {
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: startString) {
                start = date
            } else {
                // Fallback: no timezone — treat as local time
                let local = DateFormatter()
                local.locale = Locale(identifier: "en_US_POSIX")
                local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                if let date = local.date(from: startString) {
                    start = date
                } else {
                    // Last resort: use noon today so the editor still opens
                    var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                    comps.hour = 12; comps.minute = 0
                    start = Calendar.current.date(from: comps) ?? Date()
                }
            }
        }
    }
}

struct ConversationMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let question: String
    var answer: String         // var so we can stream into it via array replacement
    var sources: [SourceItem]  // var for same reason

    init(question: String, answer: String, sources: [SourceItem]) {
        self.id = UUID()
        self.question = question
        self.answer = answer
        self.sources = sources
    }

    // Used during streaming to preserve stable UUID across replacements
    init(id: UUID, question: String, answer: String, sources: [SourceItem]) {
        self.id = id
        self.question = question
        self.answer = answer
        self.sources = sources
    }
}
