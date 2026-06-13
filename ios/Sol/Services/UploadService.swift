import Foundation

// Receives URLSession delegate callbacks to forward upload byte counts.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

enum UploadError: LocalizedError {
    case noConfig
    case httpError(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noConfig: return "Not connected to a vault."
        case .httpError(let code): return "Upload failed (HTTP \(code))."
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class UploadService: ObservableObject {
    static let shared = UploadService()
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func uploadImage(_ data: Data, filename: String) async throws -> String {
        let cfg = try config()
        let boundary = UUID().uuidString
        var req = URLRequest(url: cfg.baseURL.appendingPathComponent("/api/upload/image"))
        req.httpMethod = "POST"
        req.setValue(cfg.apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let ext = (filename as NSString).pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "png":         mimeType = "image/png"
        case "gif":         mimeType = "image/gif"
        case "webp":        mimeType = "image/webp"
        default:            mimeType = "image/jpeg"
        }

        req.httpBody = buildMultipart(boundary: boundary, fieldName: "file", filename: filename, mimeType: mimeType, data: data)

        let (_, response): (Data, URLResponse)
        do { (_, response) = try await session.data(for: req) }
        catch { throw UploadError.networkError(error) }

        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw UploadError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return "![[\(filename)]]"
    }

    func uploadFile(
        at url: URL,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let cfg = try config()

        // Read file bytes off the main thread — Data(contentsOf:) is blocking.
        let (filename, data): (String, Data) = try await Task.detached(priority: .userInitiated) {
            do {
                return (url.lastPathComponent, try Data(contentsOf: url))
            } catch {
                throw UploadError.networkError(error)
            }
        }.value

        let boundary = UUID().uuidString
        var req = URLRequest(url: cfg.baseURL.appendingPathComponent("/api/upload/file"))
        req.httpMethod = "POST"
        req.setValue(cfg.apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = buildMultipart(boundary: boundary, fieldName: "file", filename: filename,
                                  mimeType: "application/octet-stream", data: data)

        let delegate = ProgressDelegate(onProgress)
        let (_, response): (Data, URLResponse)
        do { (_, response) = try await session.upload(for: req, from: body, delegate: delegate) }
        catch { throw UploadError.networkError(error) }

        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw UploadError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func config() throws -> ConnectionConfig {
        guard let c = KeychainService.load() else { throw UploadError.noConfig }
        return c
    }

    private func buildMultipart(boundary: String, fieldName: String, filename: String, mimeType: String, data: Data) -> Data {
        var body = Data()
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(data)
        body.append("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}
