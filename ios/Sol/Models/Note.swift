import Foundation

enum NoteSource: String, Codable {
    case voice, text
}

struct NoteRequest: Codable {
    let content: String
    let title: String?
    let tags: [String]?
    let source: NoteSource
}

struct NoteResponse: Codable {
    let filePath: String

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
    }
}
