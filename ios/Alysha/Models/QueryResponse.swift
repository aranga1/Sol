import Foundation

struct HistoryMessage: Codable {
    let role: String   // "user" | "assistant"
    let content: String
}

struct QueryRequest: Codable {
    let question: String
    let history: [HistoryMessage]?
}

struct SourceItem: Codable, Identifiable {
    let file: String
    let title: String
    var id: String { file }
}

struct QueryResponse: Codable {
    let answer: String
    let sources: [SourceItem]
}

struct ConversationMessage: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
    let sources: [SourceItem]
}
