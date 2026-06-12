import Foundation

struct ConnectionConfig: Codable {
    let host: String
    let port: Int
    let apiKey: String
    var vaultName: String = "Alysha"  // updated from health response on first successful check

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
}
