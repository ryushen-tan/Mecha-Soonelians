import MultipeerConnectivity
import SwiftUI

/// Multiplayer over the local network. The host phone owns the house map and the game state:
/// players send it actions, and it broadcasts the state back every time something changes.
/// The host runs the same actions locally instead of sending them.
final class GameSession: NSObject, ObservableObject {
    static let serviceType = "mecha-soon"

    @Published private(set) var state = GameState()
    @Published private(set) var ghostImages: [UUID: Data] = [:]
    @Published private(set) var ghostModels: [UUID: URL] = [:]
    /// The Mac that turns photos into 3D models. Empty means hiders use flat cutouts.
    @Published private(set) var modelServer = ModelServer(address: "", token: "")
    @Published private(set) var hosts: [MCPeerID] = []
    @Published private(set) var hostAvatars: [MCPeerID: Int] = [:]
    @Published private(set) var isConnected: Bool
    @Published private(set) var hasMap: Bool
    @Published private(set) var mapProgress = 0.0
    @Published var error: String?

    let me: Player
    let isHost: Bool
    let mapURL: URL
    let structureURL: URL

    private let peerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var hostPeer: MCPeerID?
    private var playerForPeer: [MCPeerID: UUID] = [:]
    /// Host: which player each ghost model came from. The model may arrive before its ghost, so the
    /// first sender claims the ID and nobody else can replace it.
    private var modelOwner: [UUID: UUID] = [:]
    private var timer: Timer?
    private var progressObservations: [NSKeyValueObservation] = []

    /// Where a joining phone keeps the host's house, separate from its own scan.
    private static var joinedDir: URL { HouseStore.documents.appendingPathComponent("Joined", isDirectory: true) }
    private static var ghostModelsDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GhostModels", isDirectory: true)
    }

    init(name: String, avatar: Int, isHost: Bool) {
        me = Player(id: UUID(), name: name, avatar: avatar, role: .hider, isReady: false)
        self.isHost = isHost
        isConnected = isHost
        hasMap = isHost
        mapURL = isHost ? HouseStore.worldMapURL : Self.joinedDir.appendingPathComponent("worldmap.arexperience")
        structureURL = isHost ? HouseStore.structureURL : Self.joinedDir.appendingPathComponent("structure.json")
        peerID = MCPeerID(displayName: name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
        try? FileManager.default.removeItem(at: Self.ghostModelsDir)
        try? FileManager.default.createDirectory(at: Self.ghostModelsDir, withIntermediateDirectories: true)

        if isHost {
            state.players = [me]
            modelServer = ModelServer.saved
            let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["avatar": String(avatar)],
                                                       serviceType: Self.serviceType)
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        } else {
            try? FileManager.default.removeItem(at: Self.joinedDir)
            try? FileManager.default.createDirectory(at: Self.joinedDir, withIntermediateDirectories: true)
            let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
        }
    }

    func leave() {
        timer?.invalidate()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    func join(_ host: MCPeerID) {
        hostPeer = host
        browser?.invitePeer(host, to: session, withContext: nil, timeout: 20)
    }

    var myRole: Role { state.player(me.id)?.role ?? .hider }
    var amSeeking: Bool { state.isSeeking(me.id) }
    var myGhost: Ghost? { state.ghosts.first { $0.ownerID == me.id } }

    // MARK: Player actions

    func setReady(_ ready: Bool) { send(.ready(me.id, ready)) }
    func tag(_ ghostID: UUID) { send(.tag(ghostID: ghostID, by: me.id)) }

    /// The model file goes first so it's usually there by the time the ghost is.
    func placeGhost(_ ghost: Ghost, image: Data, model: URL? = nil) {
        if let model {
            if isHost {
                modelOwner[ghost.id] = me.id
                if let stored = storeGhostModel(ghost.id, from: model, move: false) {
                    sendGhostModel(ghost.id, at: stored, to: session.connectedPeers)
                }
            } else if let hostPeer {
                session.sendResource(at: model, withName: Self.resourceName(for: ghost.id), toPeer: hostPeer, withCompletionHandler: nil)
            }
        }
        send(.placeGhost(ghost, image))
    }

    // MARK: Host actions

    func toggleRole(of playerID: UUID) {
        guard isHost, state.phase == .lobby, let i = state.players.firstIndex(where: { $0.id == playerID }) else { return }
        state.players[i].role = state.players[i].role == .hider ? .seeker : .hider
        broadcastState()
    }

    func setModelServer(_ server: ModelServer) {
        guard isHost else { return }
        modelServer = server
        server.save()
        broadcast(.modelServer(address: server.address, token: server.token))
    }

    func setDurations(hide: Int, seek: Int) {
        guard isHost else { return }
        state.hideSeconds = hide
        state.seekSeconds = seek
        broadcastState()
    }

    func startRound() {
        guard isHost, state.phase == .lobby || state.phase == .results else { return }
        state.ghosts = []
        ghostImages = [:]
        ghostModels = [:]
        modelOwner = [:]
        state.phase = .hiding
        state.secondsLeft = state.hideSeconds
        broadcastState()
    }

    func endPhase() {
        guard isHost else { return }
        switch state.phase {
        case .hiding:
            state.phase = .seeking
            state.secondsLeft = state.seekSeconds
        case .seeking:
            state.phase = .results
        case .results:
            state.phase = .lobby
        case .lobby:
            return
        }
        broadcastState()
    }

    private func tick() {
        guard state.phase == .hiding || state.phase == .seeking else { return }
        state.secondsLeft -= 1
        if state.secondsLeft <= 0 {
            endPhase()
        } else {
            broadcastState()
        }
    }

    // MARK: Messages

    private func send(_ message: Message) {
        if isHost {
            handleAsHost(message, from: nil)
        } else if let hostPeer, let data = try? JSONEncoder().encode(message) {
            try? session.send(data, toPeers: [hostPeer], with: .reliable)
        }
    }

    private func broadcast(_ message: Message, to peers: [MCPeerID]? = nil) {
        let peers = peers ?? session.connectedPeers
        guard !peers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    private func broadcastState() {
        broadcast(.state(state))
    }

    private func handleAsHost(_ message: Message, from peer: MCPeerID?) {
        switch message {
        case .hello(var player):
            if let peer { playerForPeer[peer] = player.id }
            player.isReady = false
            state.players.removeAll { $0.id == player.id }
            state.players.append(player)
            broadcastState()
            if let peer { sendHouse(to: peer) }

        case let .ready(id, ready):
            guard let i = state.players.firstIndex(where: { $0.id == id }) else { return }
            state.players[i].isReady = ready
            broadcastState()

        case let .placeGhost(ghost, image):
            // A player can only place their own ghost, under an ID whose model (if any) they sent.
            let sender = peer.flatMap { playerForPeer[$0] } ?? me.id
            guard state.phase == .hiding, ghost.ownerID == sender,
                  modelOwner[ghost.id].map({ $0 == sender }) ?? true,
                  !state.ghosts.contains(where: { $0.id == ghost.id && $0.ownerID != sender }) else { return }
            state.ghosts.removeAll { $0.ownerID == ghost.ownerID }
            state.ghosts.append(ghost)
            ghostImages[ghost.id] = image
            broadcast(.ghostImage(ghost.id, image))
            broadcastState()

        case let .tag(ghostID, by):
            guard state.phase == .seeking,
                  let i = state.ghosts.firstIndex(where: { $0.id == ghostID }),
                  state.ghosts[i].foundBy == nil else { return }
            state.ghosts[i].foundBy = by
            if state.ghosts.allSatisfy({ $0.foundBy != nil }) {
                state.phase = .results
            }
            broadcastState()

        case .state, .ghostImage, .modelServer:
            break
        }
    }

    private func handleAsPlayer(_ message: Message) {
        switch message {
        case .state(let newState):
            if newState.phase == .hiding && state.phase != .hiding {
                ghostImages = [:]
                ghostModels = [:]
            }
            state = newState
        case let .ghostImage(id, image):
            ghostImages[id] = image
        case let .modelServer(address, token):
            modelServer = ModelServer(address: address, token: token)
        case .hello, .ready, .placeGhost, .tag:
            break
        }
    }

    /// New players get the house map and walls, the 3D server, plus any ghosts already placed.
    private func sendHouse(to peer: MCPeerID) {
        session.sendResource(at: HouseStore.structureURL, withName: "structure.json", toPeer: peer, withCompletionHandler: nil)
        session.sendResource(at: HouseStore.worldMapURL, withName: "worldmap.arexperience", toPeer: peer, withCompletionHandler: nil)
        broadcast(.modelServer(address: modelServer.address, token: modelServer.token), to: [peer])
        for (id, image) in ghostImages {
            broadcast(.ghostImage(id, image), to: [peer])
        }
        for (id, url) in ghostModels {
            sendGhostModel(id, at: url, to: [peer])
        }
    }

    // MARK: Ghost models

    private static func resourceName(for ghostID: UUID) -> String { "ghost-\(ghostID.uuidString).usdz" }

    private static func ghostID(fromResourceName name: String) -> UUID? {
        guard name.hasPrefix("ghost-"), name.hasSuffix(".usdz") else { return nil }
        return UUID(uuidString: String(name.dropFirst(6).dropLast(5)))
    }

    private func sendGhostModel(_ id: UUID, at url: URL, to peers: [MCPeerID]) {
        for peer in peers {
            session.sendResource(at: url, withName: Self.resourceName(for: id), toPeer: peer, withCompletionHandler: nil)
        }
    }

    /// Keeps a model under a name built from its ghost's ID, never the sender's file name.
    @discardableResult
    private func storeGhostModel(_ id: UUID, from url: URL, move: Bool) -> URL? {
        let destination = Self.ghostModelsDir.appendingPathComponent("\(id.uuidString).usdz")
        try? FileManager.default.removeItem(at: destination)
        do {
            if move {
                try FileManager.default.moveItem(at: url, to: destination)
            } else {
                try FileManager.default.copyItem(at: url, to: destination)
            }
        } catch {
            return nil
        }
        ghostModels[id] = destination
        return destination
    }

    private func receivedFile(named name: String, at url: URL) {
        // Never build a path from the sender's file name; only these two files are expected.
        let allowed = ["structure.json": structureURL, "worldmap.arexperience": mapURL]
        guard let destination = allowed[name] else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            self.error = "Couldn't save the house map: \(error.localizedDescription)"
            return
        }
        hasMap = FileManager.default.fileExists(atPath: mapURL.path)
            && FileManager.default.fileExists(atPath: structureURL.path)
    }
}

extension GameSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [self] in
            if isHost {
                if state == .notConnected, let id = playerForPeer.removeValue(forKey: peerID) {
                    self.state.players.removeAll { $0.id == id }
                    broadcastState()
                }
            } else if peerID == hostPeer {
                switch state {
                case .connected:
                    isConnected = true
                    browser?.stopBrowsingForPeers()
                    send(.hello(me))
                case .notConnected:
                    if isConnected { error = "Lost connection to the host." }
                    isConnected = false
                default:
                    break
                }
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        DispatchQueue.main.async { [self] in
            if isHost {
                handleAsHost(message, from: peerID)
            } else {
                handleAsPlayer(message)
            }
        }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {
        guard resourceName == "worldmap.arexperience" else { return }
        let observation = progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async { self?.mapProgress = progress.fractionCompleted }
        }
        DispatchQueue.main.async { self.progressObservations.append(observation) }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // The file at localURL is deleted once this returns, so move it right away.
        let staged = localURL.map { url -> URL in
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.moveItem(at: url, to: staged)
            return staged
        }
        DispatchQueue.main.async { [self] in
            defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
            if let id = Self.ghostID(fromResourceName: resourceName) {
                // Hiders send 3D ghosts to the host, which passes them on to everyone else.
                guard error == nil, let staged else { return }
                if isHost {
                    // Only the ghost's owner may send its model.
                    guard let sender = playerForPeer[peerID],
                          state.ghosts.first(where: { $0.id == id }).map({ $0.ownerID == sender }) ?? true,
                          modelOwner[id].map({ $0 == sender }) ?? true else { return }
                    modelOwner[id] = sender
                } else {
                    guard peerID == hostPeer else { return }
                }
                guard let stored = storeGhostModel(id, from: staged, move: true) else { return }
                if isHost {
                    sendGhostModel(id, at: stored, to: session.connectedPeers.filter { $0 != peerID })
                }
                return
            }
            guard !isHost, peerID == hostPeer else { return }
            if let error {
                self.error = "Couldn't get the house map: \(error.localizedDescription)"
            } else if let staged {
                receivedFile(named: resourceName, at: staged)
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}

extension GameSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension GameSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.hosts.contains(peerID) { self.hosts.append(peerID) }
            self.hostAvatars[peerID] = info?["avatar"].flatMap { Int($0) } ?? 0
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.hosts.removeAll { $0 == peerID } }
    }
}
