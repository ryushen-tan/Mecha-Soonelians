import Foundation

struct Player: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let avatar: Int
    let host: Bool
    let ready: Bool
}

struct Room: Codable, Equatable {
    let code: String
    let locked: Bool
    let status: String
    let createdAt: String
    let members: [Player]

    var started: Bool { status == "started" }
    var readyCount: Int { members.filter(\.ready).count }
    var canStart: Bool { members.count >= 2 && readyCount == members.count && !started }
    var displayCode: String { String(code.prefix(3)) + " " + String(code.suffix(3)) }
}

struct Membership: Codable {
    let code: String
    let memberID: String
    let token: String
    let server: URL
}

struct JoinResponse: Decodable {
    let room: Room
    let memberID: String
    let token: String
}

struct RoomResponse: Decodable { let room: Room }
struct EmptyResponse: Decodable { let ok: Bool }

struct LobbyError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

enum ServerAddress {
    static func parse(_ value: String) throws -> URL {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: input),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else {
            throw LobbyError(status: 0, message: "Enter a server address, such as https://lobby.example.com.")
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { Int($0) }
        let isIPv4 = parts.count == 4 && octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
        let privateIP = isIPv4 && (octets[0] == 10 || octets[0] == 127 ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 169 && octets[1] == 254))
        let local = host == "localhost" || host == "[::1]" || host.hasSuffix(".local") || privateIP
        guard components.scheme == "https" || (components.scheme == "http" && local) else {
            throw LobbyError(status: 0, message: "Use HTTPS for an internet server, or HTTP for a local Wi-Fi address.")
        }
        return url
    }
}

struct LobbyAPI {
    let baseURL: URL
    private struct Failure: Decodable { let error: String }

    func request<Response: Decodable>(_ path: String, method: String = "GET",
        token: String? = nil, body: [String: Any]? = nil) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LobbyError(status: 0, message: "The server sent an unreadable response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw LobbyError(status: response.statusCode, message: message ?? "The server could not complete that request.")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
