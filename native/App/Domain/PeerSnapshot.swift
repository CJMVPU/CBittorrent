import Foundation

struct PeerSnapshot: Codable, Identifiable {
    var address: String
    var port: Int
    var localAddress: String
    var localPort: Int
    var client: String
    var progress: Double
    var downloadRate: Int64
    var uploadRate: Int64
    var downloaded: Int64
    var uploaded: Int64
    var transport: String
    var outgoing: Bool
    var encryption: String
    var state: String
    var uploadChoked: Bool
    var downloadChoked: Bool
    var sources: [String]

    var endpoint: String { Self.endpoint(address: address, port: port) }
    var localEndpoint: String { Self.endpoint(address: localAddress, port: localPort) }
    var id: String { "\(endpoint)|\(localEndpoint)|\(transport)|\(outgoing)" }

    private static func endpoint(address: String, port: Int) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}
