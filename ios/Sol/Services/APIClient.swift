import Foundation

enum SolAPIError: LocalizedError {
    case noConfig
    case httpError(statusCode: Int)
    case networkError(URLError)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .noConfig: return "Not connected to a vault. Please scan the QR code."
        case .httpError(let code): return "Server error (\(code))."
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError: return "Unexpected response from daemon."
        }
    }
}

// HealthResponse used by health check
struct HealthResponse: Decodable {
    let status: String
    let vaultNoteCount: Int
    let vaultName: String?        // nil on older daemon versions
    enum CodingKeys: String, CodingKey {
        case status
        case vaultNoteCount = "vault_note_count"
        case vaultName      = "vault_name"
    }
}

@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    private func config() throws -> ConnectionConfig {
        guard let c = KeychainService.load() else { throw SolAPIError.noConfig }
        return c
    }

    private func makeRequest(_ path: String, method: String = "GET") throws -> URLRequest {
        let cfg = try config()
        var req = URLRequest(url: cfg.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(cfg.apiKey, forHTTPHeaderField: "X-API-Key")
        return req
    }

    private func makeRequest<T: Encodable>(_ path: String, method: String, body: T) throws -> URLRequest {
        var req = try makeRequest(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    func health() async throws -> HealthResponse {
        var req = try makeRequest("/api/health")
        req.timeoutInterval = 5
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { return try JSONDecoder().decode(HealthResponse.self, from: data) }
        catch { throw SolAPIError.decodingError(error) }
    }

    func submitNote(_ note: NoteRequest) async throws -> NoteResponse {
        let req = try makeRequest("/api/note", method: "POST", body: note)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { return try JSONDecoder().decode(NoteResponse.self, from: data) }
        catch { throw SolAPIError.decodingError(error) }
    }

    func getSystemPrompt() async throws -> SystemPromptResponse {
        let req = try makeRequest("/api/config")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { return try JSONDecoder().decode(SystemPromptResponse.self, from: data) }
        catch { throw SolAPIError.decodingError(error) }
    }

    func updateSystemPrompt(_ prompt: String) async throws -> SystemPromptResponse {
        struct Body: Encodable { let system_prompt: String }
        let req = try makeRequest("/api/config", method: "PATCH", body: Body(system_prompt: prompt))
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { return try JSONDecoder().decode(SystemPromptResponse.self, from: data) }
        catch { throw SolAPIError.decodingError(error) }
    }

    func createTag(_ tag: String) async throws {
        struct Body: Encodable { let tag: String }
        let req = try makeRequest("/api/tags", method: "POST", body: Body(tag: tag))
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func fetchTags() async throws -> [String] {
        let req = try makeRequest("/api/tags")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Resp: Decodable { let tags: [String] }
        do { return try JSONDecoder().decode(Resp.self, from: data).tags }
        catch { throw SolAPIError.decodingError(error) }
    }

    func fetchDirectories() async throws -> [String] {
        let req = try makeRequest("/api/vault/directories")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct DirectoriesResponse: Decodable { let directories: [String] }
        do { return try JSONDecoder().decode(DirectoriesResponse.self, from: data).directories }
        catch { throw SolAPIError.decodingError(error) }
    }

    func fetchNotifications() async throws -> [DaemonNotification] {
        let req = try makeRequest("/api/notifications")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Resp: Decodable { let notifications: [DaemonNotification] }
        do { return try JSONDecoder().decode(Resp.self, from: data).notifications }
        catch { throw SolAPIError.decodingError(error) }
    }

    /// Streaming query — returns async byte stream for SSE parsing.
    func queryStream(_ q: QueryRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var req = try makeRequest("/api/query", method: "POST", body: q)
        req.timeoutInterval = 300  // streaming; long timeout for full response
        return try await session.bytes(for: req)
    }
}
