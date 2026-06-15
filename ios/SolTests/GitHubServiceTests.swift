import XCTest
@testable import Sol

// MARK: - Mock session

final class MockURLSession: URLSessionDataProtocol, @unchecked Sendable {
    var stubbedData: Data = Data()
    var stubbedStatusCode: Int = 201
    var capturedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequests.append(request)
        let url = request.url ?? URL(string: "https://api.github.com")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: stubbedStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (stubbedData, response)
    }
}

// MARK: - Tests

final class GitHubServiceTests: XCTestCase {
    var session: MockURLSession!
    var service: GitHubService!

    override func setUp() {
        session = MockURLSession()
        service = GitHubService(session: session)
    }

    func testUploadImageSendsPUT() async throws {
        let responseJSON: [String: Any] = [
            "content": ["download_url": "https://raw.githubusercontent.com/aranga1/Sol/main/feedback/attachments/abc.png"]
        ]
        session.stubbedData = try JSONSerialization.data(withJSONObject: responseJSON)
        _ = try await service.uploadImage(Data([0x89, 0x50, 0x4E, 0x47]), uuid: "abc-123")
        XCTAssertEqual(session.capturedRequests.first?.httpMethod, "PUT")
    }

    func testUploadImageReturnsDownloadURL() async throws {
        let expectedURL = "https://raw.githubusercontent.com/aranga1/Sol/main/feedback/abc.png"
        let responseJSON: [String: Any] = ["content": ["download_url": expectedURL]]
        session.stubbedData = try JSONSerialization.data(withJSONObject: responseJSON)
        let url = try await service.uploadImage(Data([0x00]), uuid: "abc-123")
        XCTAssertEqual(url, expectedURL)
    }

    func testUploadImagePathContainsUUID() async throws {
        let responseJSON: [String: Any] = [
            "content": ["download_url": "https://raw.githubusercontent.com/x/y/main/f/my-uuid.png"]
        ]
        session.stubbedData = try JSONSerialization.data(withJSONObject: responseJSON)
        _ = try await service.uploadImage(Data([0x00]), uuid: "my-uuid")
        let path = session.capturedRequests.first?.url?.path ?? ""
        XCTAssertTrue(path.contains("my-uuid"), "URL path should contain the uuid")
    }

    func testUploadImageFailsOnErrorStatus() async {
        session.stubbedStatusCode = 422
        session.stubbedData = Data()
        do {
            _ = try await service.uploadImage(Data([0x00]), uuid: "fail")
            XCTFail("Expected GitHubServiceError")
        } catch let err as GitHubServiceError {
            if case .requestFailed(let code) = err {
                XCTAssertEqual(code, 422)
            } else {
                XCTFail("Wrong error case: \(err)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCreateIssuePostsToIssuesEndpoint() async throws {
        session.stubbedData = Data("{\"number\":1}".utf8)
        try await service.createIssue(title: "t", body: "b", labels: [])
        let req = session.capturedRequests.first!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(req.url?.absoluteString.contains("/issues") == true)
    }

    func testCreateIssueSendsCorrectLabels() async throws {
        session.stubbedData = Data("{\"number\":1}".utf8)
        try await service.createIssue(title: "t", body: "b", labels: ["bug", "ios"])
        let req = session.capturedRequests.first!
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["labels"] as! [String], ["bug", "ios"])
    }

    func testCreateIssueFailsOn403() async {
        session.stubbedStatusCode = 403
        session.stubbedData = Data()
        do {
            try await service.createIssue(title: "t", body: "b", labels: [])
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is GitHubServiceError)
        }
    }

    func testCreateIssueSendsBearerAuth() async throws {
        session.stubbedData = Data("{\"number\":1}".utf8)
        try await service.createIssue(title: "t", body: "b", labels: [])
        let authHeader = session.capturedRequests.first?.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(authHeader.hasPrefix("Bearer "), "Must use Bearer scheme")
    }
}
