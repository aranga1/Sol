import Foundation

struct ConversationSession: Identifiable, Codable, Hashable {
    let id: UUID
    let startedAt: Date
    var messages: [ConversationMessage]

    var title: String { messages.first?.question ?? "Untitled" }
}
