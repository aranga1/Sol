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
    let type: String          // "token" | "sources" | "done" | "error"
    let content: String?      // present for type=token and type=error
    let sources: [SourceItem]? // present for type=sources
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
