import Foundation
import simd

enum Role: String, Codable {
    case hider, seeker
}

enum Phase: String, Codable {
    case lobby, hiding, seeking, results
}

struct Player: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// One of Rally's six avatar faces.
    var avatar: Int
    var role: Role
    /// Has the house map and has recognized the house.
    var isReady: Bool
}

/// A painted cutout of a hider, pinned in house coordinates. The image is sent separately
/// (once) so the state the host broadcasts every second stays small.
struct Ghost: Codable, Identifiable, Equatable {
    let id: UUID
    let ownerID: UUID
    /// Center of the flat cutout.
    var transform: [Float]
    /// Where a 3D model stands: on the floor, facing +Z.
    var floorTransform: [Float]
    /// The 3D model's back goes against a wall at `floorTransform`.
    var flushBack: Bool
    /// A painted 3D model (USDZ) travels separately; until it arrives, the cutout shows.
    var hasModel: Bool
    /// The model is a spray-painted chameleon and the image is its paint, not a cutout.
    var paintedBody = false
    var width: Float
    var height: Float
    var foundBy: UUID?
}

struct GameState: Codable, Equatable {
    var phase = Phase.lobby
    var players: [Player] = []
    var ghosts: [Ghost] = []
    var secondsLeft = 0
    var hideSeconds = 300
    var seekSeconds = 300

    func player(_ id: UUID?) -> Player? {
        players.first { $0.id == id }
    }

    /// With nobody set as seeker (e.g. testing alone), everyone seeks.
    func isSeeking(_ id: UUID) -> Bool {
        player(id)?.role == .seeker || !players.contains { $0.role == .seeker }
    }
}

enum Message: Codable {
    // Player → host
    case hello(Player)
    case ready(UUID, Bool)
    case placeGhost(Ghost, Data)
    case tag(ghostID: UUID, by: UUID)
    // Host → players
    case state(GameState)
    case ghostImage(UUID, Data)
    /// Where hiders' phones reach the Mac that makes 3D models. Sent only over the encrypted session.
    case modelServer(address: String, token: String)
}

extension simd_float4x4 {
    /// 16 floats, column by column.
    var floats: [Float] {
        [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    init?(floats m: [Float]) {
        guard m.count == 16 else { return nil }
        self.init((0..<4).map { SIMD4<Float>(m[$0 * 4 ..< $0 * 4 + 4]) })
    }
}
