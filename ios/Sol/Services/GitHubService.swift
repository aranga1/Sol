import Foundation

// Protocol for URLSession injection in tests
protocol URLSessionDataProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionDataProtocol {}

enum GitHubServiceError: LocalizedError {
    case requestFailed(Int)
    case missingDownloadURL

    var errorDescription: String? {
        switch self {
        case .requestFailed(let code): return "GitHub API error (\(code))"
        case .missingDownloadURL: return "Image upload response missing download_url"
        }
    }
}

struct GitHubService {
    let session: URLSessionDataProtocol
    private let pat = BuildSecrets.githubIssuesPAT
    private let repo = BuildSecrets.githubRepo
    private let base = "https://api.github.com"

    init(session: URLSessionDataProtocol = URLSession.shared) {
        self.session = session
    }

    func uploadImage(_ data: Data, uuid: String) async throws -> String {
        let path = "feedback/attachments/\(uuid).jpg"
        guard let url = URL(string: "\(base)/repos/\(repo)/contents/\(path)") else {
            throw GitHubServiceError.requestFailed(0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "message": "feedback attachment \(uuid)",
            "content": data.base64EncodedString()
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw GitHubServiceError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let content = json["content"] as? [String: Any],
            let downloadURL = content["download_url"] as? String
        else { throw GitHubServiceError.missingDownloadURL }
        return downloadURL
    }

    func createIssue(title: String, body: String, labels: [String]) async throws {
        guard let url = URL(string: "\(base)/repos/\(repo)/issues") else {
            throw GitHubServiceError.requestFailed(0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["title": title, "body": body, "labels": labels]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw GitHubServiceError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
