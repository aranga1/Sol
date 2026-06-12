import Foundation

@Observable
@MainActor
final class TagStore {
    static let shared = TagStore()

    private(set) var tags: [String] = []
    private var lastFetch: Date?
    private let cacheTTL: TimeInterval = 300  // 5 minutes

    private init() {}

    /// Fetch from daemon if cache is stale (>5 min) or empty. Safe to call on every composer open.
    func fetchIfNeeded() async {
        if let last = lastFetch, Date().timeIntervalSince(last) < cacheTTL, !tags.isEmpty { return }
        do {
            let fetched = try await APIClient.shared.fetchTags()
            tags = fetched
            lastFetch = Date()
        } catch {
            // Keep existing cache on network error — tags are best-effort
        }
    }

    /// Create a new tag in the vault and add it to the local cache immediately.
    func createTag(_ tag: String) async {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !clean.isEmpty, !tags.contains(clean) else { return }
        tags.append(clean)  // optimistic local update
        tags.sort()
        do {
            try await APIClient.shared.createTag(clean)
        } catch {
            // Don't roll back — tag is still useful locally even if persist fails
        }
    }

    /// Synchronously filter tags matching a query string (case-insensitive prefix/contains).
    func suggestions(for query: String, excluding selected: [String]) -> [String] {
        guard !query.isEmpty else {
            return tags.filter { !selected.contains($0) }.prefix(8).map { $0 }
        }
        let q = query.lowercased()
        return tags
            .filter { !selected.contains($0) && $0.lowercased().contains(q) }
            .prefix(8)
            .map { $0 }
    }
}
