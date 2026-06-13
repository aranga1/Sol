import Foundation

struct CreateEventPayload: Decodable {
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
        title = try container.decode(String.self, forKey: .title)
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
