import Foundation

struct SystemPromptResponse: Codable {
    let systemPrompt: String
    let defaultSystemPrompt: String
    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case defaultSystemPrompt = "default_system_prompt"
    }
}
