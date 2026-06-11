import Foundation

struct QueryRequest: Codable {
    let question: String
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
