import SwiftUI

/// One online AR round. The server owns the game: it picks the seeker, runs the timers, decides
/// who may see which ghost, and records tags. This class polls it once a second and mirrors the
/// answer into `state`, and it moves the big files (the scanned house, each ghost's picture and
/// 3D model) straight to and from Storage on short-lived signed URLs.
@MainActor
final class GameSession: ObservableObject {
    @Published private(set) var state = GameState()
    @Published private(set) var ghostImages: [UUID: Data] = [:]
    @Published private(set) var ghostModels: [UUID: URL] = [:]
    @Published private(set) var hasMap: Bool
    @Published private(set) var mapProgress = 0.0
    @Published private(set) var reconnecting = false
    /// The room is gone (the host closed it, or this player was removed).
    @Published private(set) var roomGone = false
    @Published var error: String?

    let me: Player
    let isHost: Bool
    /// Where the world map and room structure are read from; set before `hasMap` turns true.
    private(set) var mapURL: URL
    private(set) var structureURL: URL

    private let connection: GameConnection
    private var poller: Task<Void, Never>?
    private var loadingGhosts: Set<UUID> = []
    private var loadingHouse = false
    private var optimisticGhost: Ghost?

    /// Where a joining phone keeps the host's house, separate from its own scan.
    private static var joinedDir: URL { HouseStore.documents.appendingPathComponent("Joined", isDirectory: true) }
    private static var ghostModelsDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GhostModels", isDirectory: true)
    }

    init(connection: GameConnection, name: String, avatar: Int) {
        self.connection = connection
        isHost = connection.isHost
        me = Player(id: UUID(uuidString: connection.memberID) ?? UUID(), name: name, avatar: avatar, role: .hider, isReady: false)
        mapURL = isHost ? HouseStore.activeWorldMapURL : Self.joinedDir.appendingPathComponent("worldmap.arexperience")
        structureURL = isHost ? HouseStore.activeStructureURL : Self.joinedDir.appendingPathComponent("structure.json")
        hasMap = isHost && HouseStore.source != .none
        try? FileManager.default.removeItem(at: Self.ghostModelsDir)
        try? FileManager.default.createDirectory(at: Self.ghostModelsDir, withIntermediateDirectories: true)
        if !isHost {
            try? FileManager.default.removeItem(at: Self.joinedDir)
            try? FileManager.default.createDirectory(at: Self.joinedDir, withIntermediateDirectories: true)
        }
    }

    deinit { poller?.cancel() }

    var myRole: Role { state.player(me.id)?.role ?? .hider }
    var amSeeking: Bool { state.isSeeking(me.id) }
    var myGhost: Ghost? { state.ghosts.first { $0.ownerID == me.id } }
    var seeker: Player? { state.player(state.seekerID) }

    // MARK: Polling

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func leave() {
        poller?.cancel()
        poller = nil
    }

    private func refresh() async {
        do {
            let reply: RoundReply = try await call("ar")
            reconnecting = false
            guard var next = reply.ar else { return }
            if let optimisticGhost, !next.ghosts.contains(where: { $0.id == optimisticGhost.id }), next.phase == .hiding {
                next.ghosts.append(optimisticGhost) // Placed here, not yet in the server's answer.
            } else if optimisticGhost != nil, next.ghosts.contains(where: { $0.id == optimisticGhost?.id }) {
                optimisticGhost = nil
            }
            if state.phase != .hiding && next.phase == .hiding {
                ghostImages = [:]
                ghostModels = [:]
            }
            if next != state { state = next }
            await loadHouseIfNeeded()
            loadMissingGhosts()
        } catch let failure as LobbyError where [401, 404].contains(failure.status) {
            roomGone = true
        } catch {
            reconnecting = true
        }
    }

    // MARK: Player actions

    func setReady(_ ready: Bool) { act(["action": "ready", "ready": ready]) }
    func tag(_ ghostID: UUID) { act(["action": "tag", "ghostID": ghostID.uuidString.lowercased()]) }
    /// Host: start hiding without waiting for everyone to find the house.
    func startRound() { act(["action": "begin"]) }
    /// Host: hiding -> seeking, or seeking -> results, ahead of the clock.
    func skipPhase() { act(["action": "skip"]) }
    /// Host: another round, with a newly picked seeker.
    func playAgain() {
        var body: [String: Any] = ["action": "start", "hideSeconds": state.hideSeconds, "seekSeconds": state.seekSeconds]
        if let house = state.house, house.kind == "bundled", let id = house.id { body["house"] = ["kind": "bundled", "id": id] }
        act(body)
    }

    private func act(_ body: [String: Any]) {
        Task {
            do {
                let reply: RoundReply = try await call("ar", method: "POST", body: body)
                if let next = reply.ar { state = next }
            } catch { self.error = Self.describe(error) }
        }
    }

    /// Hides the player here. The picture and any 3D model upload first; the server only accepts the
    /// ghost once both are in Storage.
    func placeGhost(_ ghost: Ghost, image: Data, model: URL? = nil) {
        var ghost = ghost
        ghost.modelFormat = model.map { $0.pathExtension }
        var localModel: URL?
        if let model, let kept = keepGhostModel(ghost.id, from: model) { localModel = kept }
        ghostImages[ghost.id] = image
        if let localModel { ghostModels[ghost.id] = localModel }
        optimisticGhost = ghost
        state.ghosts.removeAll { $0.ownerID == me.id }
        state.ghosts.append(ghost)
        let placed = ghost
        Task {
            do {
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(placed))
                let urls: GhostUploadURLs = try await call("ar/ghosts", method: "POST", body: ["ghost": object])
                try await upload(image, to: urls.image.url)
                if let localModel, let target = urls.model?.url {
                    try await upload(try Data(contentsOf: localModel), to: target)
                }
                let reply: RoundReply = try await call("ar", method: "POST", body: ["action": "place", "ghost": object])
                if let next = reply.ar { state = next }
            } catch {
                self.error = "Couldn't hide your ghost: \(Self.describe(error))"
                if optimisticGhost?.id == placed.id { optimisticGhost = nil }
                state.ghosts.removeAll { $0.id == placed.id }
            }
        }
    }

    // MARK: The house

    private func loadHouseIfNeeded() async {
        guard !hasMap, !loadingHouse, !isHost else { return }
        if let house = state.house, house.kind == "bundled" {
            // Every build carries the same scan, so there is nothing to download.
            if let id = house.id, id == HouseStore.bundledID,
               let map = HouseStore.bundledWorldMapURL, let structure = HouseStore.bundledStructureURL {
                mapURL = map
                structureURL = structure
                hasMap = true
            } else {
                error = "This game is in a different house than your app has. Update Mecha Soonelians and try again."
            }
            return
        }
        loadingHouse = true
        defer { loadingHouse = false }
        do {
            let urls: HouseURLs = try await call("ar/house")
            let downloader = FileDownloader { [weak self] fraction in
                Task { @MainActor in self?.mapProgress = fraction }
            }
            try await downloader.download(urls.structure.url, to: structureURL)
            try await downloader.download(urls.worldmap.url, to: mapURL)
            hasMap = FileManager.default.fileExists(atPath: mapURL.path) && FileManager.default.fileExists(atPath: structureURL.path)
        } catch {
            self.error = "Couldn't get the house map: \(Self.describe(error))"
        }
    }

    // MARK: Ghosts

    private func loadMissingGhosts() {
        for ghost in state.ghosts where ghostImages[ghost.id] == nil && !loadingGhosts.contains(ghost.id) {
            loadingGhosts.insert(ghost.id)
            Task {
                defer { loadingGhosts.remove(ghost.id) }
                do {
                    let assets: GhostDownloadURLs = try await call("ar/ghosts/\(ghost.id.uuidString.lowercased())")
                    let (imageFile, imageResponse) = try await URLSession.shared.download(from: assets.image.url)
                    try Self.requireSuccess(imageResponse)
                    let image = try Data(contentsOf: imageFile)
                    try? FileManager.default.removeItem(at: imageFile)
                    if let model = assets.model?.url, let format = assets.modelFormat {
                        let (file, modelResponse) = try await URLSession.shared.download(from: model)
                        try Self.requireSuccess(modelResponse)
                        let name = Self.ghostModelsDir.appendingPathComponent("incoming-\(ghost.id.uuidString).\(format)")
                        try? FileManager.default.removeItem(at: name)
                        try FileManager.default.moveItem(at: file, to: name)
                        _ = keepGhostModel(ghost.id, from: name, move: true)
                    }
                    ghostImages[ghost.id] = image
                } catch {
                    // It stays missing and is tried again on the next poll.
                }
            }
        }
    }

    /// Keeps a model under a name built from its ghost's ID, never a sender's file name.
    @discardableResult
    private func keepGhostModel(_ id: UUID, from url: URL, move: Bool = false) -> URL? {
        let format = url.pathExtension
        guard ["usdz", "body"].contains(format),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 100 * 1024 * 1024 else { return nil }
        if format == "body" {
            guard let archive = try? JSONDecoder().decode(CharacterBodyArchive.self, from: Data(contentsOf: url)),
                  archive.info.poses.count == 1, archive.isValid else { return nil }
        }
        let destination = Self.ghostModelsDir.appendingPathComponent("\(id.uuidString).\(format)")
        try? FileManager.default.removeItem(at: destination)
        do {
            if move { try FileManager.default.moveItem(at: url, to: destination) }
            else { try FileManager.default.copyItem(at: url, to: destination) }
        } catch { return nil }
        ghostModels[id] = destination
        return destination
    }

    // MARK: Network

    private func call<Response: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Response {
        try await LobbyAPI(baseURL: connection.server).request("rooms/\(connection.code)/\(path)",
            method: method, token: connection.token, body: body)
    }

    private func upload(_ data: Data, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LobbyError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "The upload didn't go through. Try again.")
        }
    }

    /// A download that came back as an error page must not be treated as the file.
    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LobbyError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "A ghost file didn't download.")
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LobbyError)?.message ?? "Check your connection and try again."
    }
}

// MARK: Server replies

private struct RoundReply: Decodable { let ar: GameState? }
private struct SignedURL: Decodable { let url: URL }
private struct HouseURLs: Decodable { let structure: SignedURL; let worldmap: SignedURL }
private struct GhostUploadURLs: Decodable { let image: SignedURL; let model: SignedURL? }
private struct GhostDownloadURLs: Decodable { let image: SignedURL; let model: SignedURL?; let modelFormat: String? }

/// Downloads a file to a fixed place, reporting progress.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(progress: @escaping (Double) -> Void) { self.progress = progress }

    func download(_ url: URL, to destination: URL) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.finishTasksAndInvalidate() }
        let file = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes the file when this returns, so keep it.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LobbyError(status: http.statusCode, message: "The download didn't go through (\(http.statusCode)).")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch { continuation?.resume(throwing: error) }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}
