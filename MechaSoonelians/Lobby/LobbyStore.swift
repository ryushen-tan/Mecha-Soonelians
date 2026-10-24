import SwiftUI

@MainActor
final class LobbyStore: ObservableObject {
    @Published private(set) var room: Room?
    @Published private(set) var membership: Membership?
    @Published private(set) var busy = false
    @Published private(set) var reconnecting = false
    @Published var error: String?
    /// What the host is doing while a round starts ("Uploading your house…").
    @Published private(set) var startingStatus: String?
    /// How long hiders get to hide, and the seeker to seek.
    @Published var hideMinutes = 5
    @Published var seekMinutes = 5
    @Published var nickname: String { didSet { UserDefaults.standard.set(nickname, forKey: "nickname") } }
    @Published var avatar: Int { didSet { UserDefaults.standard.set(avatar, forKey: "avatar") } }
    @Published var serverAddress: String { didSet { UserDefaults.standard.set(serverAddress, forKey: "server") } }
    private var generation = 0

    init() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ui-testing") {
            SessionVault.clear()
            for key in ["nickname", "avatar", "server"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        nickname = UserDefaults.standard.string(forKey: "nickname") ?? ""
        avatar = min(5, max(0, UserDefaults.standard.integer(forKey: "avatar")))
        serverAddress = UserDefaults.standard.string(forKey: "server") ?? "https://mecha-soonelians.vercel.app"
        if let index = args.firstIndex(of: "-server-url"), args.indices.contains(index + 1) {
            serverAddress = args[index + 1]
        }
        membership = SessionVault.read()
    }

    var me: LobbyPlayer? { room?.members.first { $0.id == membership?.memberID } }
    var isHost: Bool { me?.host == true }
    var validName: Bool {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.unicodeScalars.count <= 20 &&
            name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    func reloadServerAddress() {
        guard !ProcessInfo.processInfo.arguments.contains("-server-url"),
              let address = UserDefaults.standard.string(forKey: "server"),
              address != serverAddress else { return }
        serverAddress = address
    }

    func enter(code: String? = nil) async -> Bool {
        guard !busy, membership == nil else { return false }
        guard validName else { error = "Choose a name between 1 and 20 characters."; return false }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let url = try ServerAddress.parse(serverAddress)
            let body: [String: Any] = ["name": nickname.trimmingCharacters(in: .whitespacesAndNewlines), "avatar": avatar]
            let path = code.map { "rooms/\($0)/join" } ?? "rooms"
            let result: JoinResponse = try await LobbyAPI(baseURL: url).request(path, method: "POST", body: body)
            let session = Membership(code: result.room.code, memberID: result.memberID, token: result.token, server: url)
            generation += 1
            membership = session
            room = result.room
            reconnecting = false
            SessionVault.save(session)
            return true
        } catch { self.error = describe(error); return false }
    }

    func refresh() async {
        guard let session = membership, !busy else { return }
        let revision = generation
        do {
            let result: RoomResponse = try await LobbyAPI(baseURL: session.server).request("rooms/\(session.code)", token: session.token)
            guard generation == revision, membership?.token == session.token else { return }
            room = result.room
            reconnecting = false
        } catch {
            guard generation == revision, membership?.token == session.token else { return }
            if let failure = error as? LobbyError, [401, 404].contains(failure.status) {
                clearSession()
                self.error = failure.message
            } else { reconnecting = true }
        }
    }

    func setReady() async {
        guard let me else { return }
        await mutate(suffix: "/me", body: ["ready": !me.ready])
    }

    func setLocked() async {
        guard let room else { return }
        await mutate(body: ["locked": !room.locked])
    }

    /// Uploads the host's scanned house, then the server picks a seeker at random and starts the AR round.
    func start() async {
        guard let session = membership, !busy else { return }
        guard HouseStore.hasHouse else {
            error = "Scan your house first (Studio → Scan your house) so there's somewhere to hide."
            return
        }
        busy = true
        error = nil
        generation += 1
        defer { busy = false; startingStatus = nil }
        do {
            let api = LobbyAPI(baseURL: session.server)
            let path = "rooms/\(session.code)"
            startingStatus = "Uploading your house…"
            let urls: HouseUploadURLs = try await api.request("\(path)/ar/house", method: "POST", token: session.token)
            try await upload(HouseStore.structureURL, to: urls.structure.url)
            try await upload(HouseStore.worldMapURL, to: urls.worldmap.url)
            startingStatus = "Choosing a seeker…"
            let _: EmptyReply = try await api.request("\(path)/ar", method: "POST", token: session.token,
                body: ["action": "start", "hideSeconds": hideMinutes * 60, "seekSeconds": seekMinutes * 60])
            let result: RoomResponse = try await api.request(path, token: session.token)
            guard membership?.token == session.token else { return }
            room = result.room
            reconnecting = false
        } catch {
            if let failure = error as? LobbyError, [401, 404].contains(failure.status) { clearSession() }
            self.error = describe(error)
        }
    }

    private func upload(_ file: URL, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LobbyError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                             message: "Your house didn't finish uploading. Check your connection and try again.")
        }
    }
    func reset() async { await mutate(body: ["status": "waiting"]) }
    func remove(_ player: LobbyPlayer) async { await mutate(suffix: "/members/\(player.id)", method: "DELETE") }

    private func mutate(suffix: String = "", method: String = "PATCH", body: [String: Any]? = nil) async {
        guard let session = membership, !busy else { return }
        busy = true
        error = nil
        generation += 1 // Discard polls issued before this mutation.
        defer { busy = false }
        do {
            let result: RoomResponse = try await LobbyAPI(baseURL: session.server).request("rooms/\(session.code)\(suffix)",
                method: method, token: session.token, body: body)
            guard membership?.token == session.token else { return }
            room = result.room
            reconnecting = false
        } catch {
            if let failure = error as? LobbyError, [401, 404].contains(failure.status) {
                clearSession()
            }
            self.error = describe(error)
        }
    }

    func leave() async {
        guard let session = membership, !busy else { return }
        busy = true
        error = nil
        generation += 1
        defer { busy = false }
        do {
            let _: EmptyResponse = try await LobbyAPI(baseURL: session.server).request("rooms/\(session.code)/leave", method: "POST", token: session.token)
        } catch {
            self.error = "You left on this device. The server couldn’t be reached; your spot will expire within 90 seconds."
        }
        clearSession()
    }

    private func clearSession() {
        generation += 1
        membership = nil
        room = nil
        reconnecting = false
        SessionVault.clear()
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? LobbyError { return error.message }
        if error is DecodingError { return "This address isn’t responding as a Rally server. Check Server settings." }
        return "Can’t reach the lobby server. Check your connection and the address in Server settings, then try again."
    }
}

private struct SignedUpload: Decodable { let url: URL }
private struct HouseUploadURLs: Decodable { let structure: SignedUpload; let worldmap: SignedUpload }
private struct EmptyReply: Decodable {}
