import Foundation

struct ConnectionConfig: Codable {
    let host: String
    let port: Int
    let apiKey: String

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
}
