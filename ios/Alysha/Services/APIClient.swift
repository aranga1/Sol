import Foundation

enum AlyshAPIError: LocalizedError {
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
    enum CodingKeys: String, CodingKey {
        case status
        case vaultNoteCount = "vault_note_count"
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
        guard let c = KeychainService.load() else { throw AlyshAPIError.noConfig }
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
            throw AlyshAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { return try JSONDecoder().decode(HealthResponse.self, from: data) }
        catch { throw AlyshAPIError.decodingError(error) }
    }

    func submitNote(_ note: NoteRequest) async throws -> NoteResponse {
        let req = try makeRequest("/api/note", method: "POST", body: note)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw AlyshAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { return try JSONDecoder().decode(NoteResponse.self, from: data) }
        catch { throw AlyshAPIError.decodingError(error) }
    }

    func query(_ q: QueryRequest) async throws -> QueryResponse {
        let req = try makeRequest("/api/query", method: "POST", body: q)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AlyshAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do { return try JSONDecoder().decode(QueryResponse.self, from: data) }
        catch { throw AlyshAPIError.decodingError(error) }
    }
}
