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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: startString) {
            start = date
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: startString) {
                start = date
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .start, in: container,
                    debugDescription: "Cannot parse date: \(startString)"
                )
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
