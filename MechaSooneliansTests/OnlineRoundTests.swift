import XCTest
import UIKit
import simd
@testable import MechaSoonelians

/// Plays a real two-player round against the live server: one phone hides a spray-painted chameleon,
/// the other seeks. Everything is real except the camera.
@MainActor
final class OnlineRoundTests: XCTestCase {
    private let server = URL(string: "https://mecha-soonelians.vercel.app")!

    private func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let seconds = 30.0
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for: \(message)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func testAHidersGhostReachesTheSeekerAndIsDrawnThenCanBeFound() async throws {
        try await playRound(skipWhileUploading: false)
    }

    /// The host ends hiding while a hider's ghost is still uploading: the ghost must still count.
    func testAHideStillLandsWhenHidingEndsMidUpload() async throws {
        try await playRound(skipWhileUploading: true)
    }

    private func playRound(skipWhileUploading: Bool) async throws {
        let api = LobbyAPI(baseURL: server)
        let houseID = try XCTUnwrap(HouseStore.bundledID, "The house should be bundled in the app.")
        let host: JoinResponse = try await api.request("rooms", method: "POST", body: ["name": "Test host", "avatar": 0])
        let code = host.room.code
        let guest: JoinResponse = try await api.request("rooms/\(code)/join", method: "POST", body: ["name": "Test guest", "avatar": 1])
        defer { Task { let _: EmptyResponse? = try? await api.request("rooms/\(code)/leave", method: "POST", token: host.token) } }
        let _: RoomResponse = try await api.request("rooms/\(code)/me", method: "PATCH", token: guest.token, body: ["ready": true])
        struct Started: Decodable {}
        let _: Started = try await api.request("rooms/\(code)/ar", method: "POST", token: host.token,
            body: ["action": "start", "hideSeconds": 120, "seekSeconds": 120, "house": ["kind": "bundled", "id": houseID]])

        let hostSession = GameSession(connection: GameConnection(server: server, code: code, memberID: host.memberID, token: host.token, isHost: true), name: "Test host", avatar: 0)
        let guestSession = GameSession(connection: GameConnection(server: server, code: code, memberID: guest.memberID, token: guest.token, isHost: false), name: "Test guest", avatar: 1)
        defer { hostSession.leave(); guestSession.leave() }
        hostSession.start(); guestSession.start()

        try await eventually("both phones see a seeker") { hostSession.state.seekerID != nil && guestSession.state.seekerID != nil }
        XCTAssertEqual(hostSession.state.players.filter { $0.role == .seeker }.count, 1, "Exactly one seeker")
        let seekerIsHost = hostSession.state.seekerID == hostSession.me.id
        let seeker = seekerIsHost ? hostSession : guestSession
        let hider = seekerIsHost ? guestSession : hostSession
        let hiderToken = seekerIsHost ? guest.token : host.token

        try await eventually("the guest has the bundled house") { guestSession.hasMap }
        XCTAssertEqual(guestSession.mapURL, HouseStore.bundledWorldMapURL)
        hostSession.setReady(true); guestSession.setReady(true)
        try await eventually("hiding starts") { hider.state.phase == .hiding && seeker.state.phase == .hiding }
        XCTAssertTrue(hider.myRole == .hider && seeker.myRole == .seeker)

        // A real spray-painted chameleon, exactly as the hiding screen exports it.
        // The host skips to seeking the moment the hide starts uploading (the reported bug).
        let body = try XCTUnwrap(ChameleonBody.shared)
        let poseIndex = try XCTUnwrap(body.index(of: "crouch"))
        let id = UUID()
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-\(id.uuidString).body")
        try body.exportedPose(poseIndex).write(to: bodyFile)
        let paint = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        })
        let spot = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(1, 0, 2, 1)))
        hider.placeGhost(Ghost(id: id, ownerID: hider.me.id, transform: spot.floats, floorTransform: spot.floats, flushBack: false,
            hasModel: true, paintedBody: true, pose: "crouch", width: 0.875, height: 1.75, foundBy: nil), image: paint, model: bodyFile)
        XCTAssertNil(hider.error)
        if skipWhileUploading { hostSession.skipPhase() }
        try await eventually("the hide finishes uploading") { !hider.placing }
        XCTAssertNil(hider.error, "The hide must still land after hiding ends: \(hider.error ?? "")")

        // The server must really have it (not just the hider's own screen).
        let hiderView: ARReply = try await {
            for _ in 0..<40 {
                let reply: ARReply = try await api.request("rooms/\(code)/ar", token: hiderToken)
                if reply.ar?.ghosts.count == 1 { return reply }
                try await Task.sleep(for: .milliseconds(250))
            }
            XCTFail("The server never saved the ghost: \(hider.error ?? "no error")"); throw CancellationError()
        }()
        XCTAssertEqual(hiderView.ar?.ghosts.first?.id, id)
        if !skipWhileUploading {
            XCTAssertEqual(seeker.state.ghosts.count, 0, "The seeker can't see ghosts while everyone hides")
            hostSession.skipPhase()
        }
        try await eventually("seeking starts") { seeker.state.phase == .seeking && hider.state.phase == .seeking }
        try await eventually("the seeker's phone lists the ghost") { seeker.state.ghosts.count == 1 }
        try await eventually("the ghost's picture and 3D body arrive on the seeker's phone") { seeker.ghostImages[id] != nil && seeker.ghostModels[id] != nil }
        XCTAssertEqual(seeker.ghostModels[id]?.pathExtension, "body")

        // Drawn exactly as the game screen does it.
        let ar = ARGameController()
        ar.show(seeker.state.ghosts, images: seeker.ghostImages, models: seeker.ghostModels)
        XCTAssertEqual(ar.shownGhostCount, 1, "The seeker's AR scene should contain the hider's chameleon")

        // Chirps: the hider chirps, the seeker hears it from that ghost, and spamming is refused.
        XCTAssertNotNil(ARGameController.makeChirpSound(), "The chirp sound should load")
        hider.chirp()
        try await eventually("the seeker receives the chirp") { seeker.state.chirps?.contains { $0.ghostID == id } == true }
        XCTAssertNil(hider.error)
        hider.chirp()
        try await eventually("a second chirp straight away is refused") { hider.error != nil }
        hider.error = nil
        seeker.chirp()
        try await eventually("the seeker can't chirp") { seeker.error != nil }
        seeker.error = nil

        // Points: the seeker reports seeing the hider for ~3 s, and the hider gains points (10/s).
        for _ in 0..<4 { seeker.reportSeen([id]); try await Task.sleep(for: .seconds(1)) }
        try await eventually("the hider earns points for being seen") { (hider.state.player(hider.me.id)?.points ?? 0) >= 20 }
        XCTAssertEqual(hider.state.player(hider.me.id)?.seenNow, true)

        seeker.tag(id)
        try await eventually("the ghost is found and the round ends") { seeker.state.phase == .results && seeker.state.ghosts.first?.foundBy == seeker.me.id }
        XCTAssertEqual(seeker.state.winnerIDs, [seeker.me.id], "Finding everyone wins it for the seeker")
        // A double tap on the last ghost reaches the server after the round ended: it must be ignored.
        let seekerToken = seekerIsHost ? host.token : guest.token
        struct Reply: Decodable {}
        let _: Reply = try await api.request("rooms/\(code)/ar", method: "POST", token: seekerToken,
            body: ["action": "tag", "ghostID": id.uuidString.lowercased()])
        seeker.tag(id)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(seeker.error, "A late tap must not show an error")
    }
}

private struct ARReply: Decodable { let ar: GameState? }
