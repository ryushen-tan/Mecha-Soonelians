import Foundation

// Compile alongside Rally/Models.swift to exercise the native client against a real server.
@main struct NativeAPISmoke {
    static func main() async throws {
        let api = LobbyAPI(baseURL: try ServerAddress.parse(CommandLine.arguments.dropFirst().first ?? "http://localhost:3000"))
        let host: JoinResponse = try await api.request("rooms", method: "POST", body: ["name": "Swift Host", "avatar": 0, "capacity": 4])
        let path = "rooms/\(host.room.code)"
        let guest: JoinResponse = try await api.request(path + "/join", method: "POST", body: ["name": "Swift Guest", "avatar": 1])
        let snapshot: RoomResponse = try await api.request(path, token: host.token)
        precondition(snapshot.room.members.count == 2)
        precondition(!snapshot.room.canStart)
        let _: RoomResponse = try await api.request(path + "/me", method: "PATCH", token: guest.token, body: ["ready": true])
        let started: RoomResponse = try await api.request(path, method: "PATCH", token: host.token, body: ["status": "started"])
        precondition(started.room.started && started.room.locked)
        let _: EmptyResponse = try await api.request(path + "/leave", method: "POST", token: host.token)
        do {
            let _: RoomResponse = try await api.request(path, token: guest.token)
            fatalError("An ended room must be gone")
        } catch let error as LobbyError { precondition(error.status == 404) }
        print("Native API smoke passed: create → join → poll → ready → start → end.")
    }
}
