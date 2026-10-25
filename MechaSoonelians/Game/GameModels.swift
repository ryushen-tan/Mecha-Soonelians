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
    /// Points from being in the seeker's view without being found.
    var points: Int?
    /// All points across consecutive rounds in this room, including the current round.
    var totalPoints: Int?
    /// This player is a hider the seeker is looking at right now (only told to that hider).
    var seenNow: Bool?
}

/// A painted cutout of a hider, pinned in house coordinates. The image and any 3D model are
/// separate files in Storage, so the state the server returns every second stays small.
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
    /// A spray-painted chameleon in `pose` (see ChameleonBody); the image is its paint, not a cutout.
    var paintedBody = false
    var pose: String?
    var width: Float
    var height: Float
    var foundBy: UUID?
    /// "usdz" for a painted 3D ghost, "body" for a spray-painted chameleon; nil without a model.
    var modelFormat: String?
}

struct HouseRef: Codable, Equatable {
    let kind: String
    let id: String?
}

/// A hider made their ghost chirp. `age` is how long ago, in milliseconds, when the server answered.
struct Chirp: Codable, Equatable, Identifiable {
    let id: String
    let ghostID: UUID
    let ownerID: UUID
    let age: Double
}

struct GameState: Codable, Equatable {
    var phase = Phase.lobby
    var players: [Player] = []
    var ghosts: [Ghost] = []
    var secondsLeft = 0
    var hideSeconds = 300
    var seekSeconds = 300
    /// The one player picked at random to seek this round.
    var seekerID: UUID?
    /// Which house the round is in: the one inside the app, or one the host uploaded.
    var house: HouseRef?
    var chirps: [Chirp]?
    /// Who won, once the round is over: the seeker, or the hidden hider(s) with the most points.
    var winnerIDs: [UUID]?
    var roundNumber: Int?

    /// Stable order for tied totals; each tied player receives the same competition rank.
    var leaderboard: [Player] {
        players.sorted {
            let left = $0.totalPoints ?? $0.points ?? 0
            let right = $1.totalPoints ?? $1.points ?? 0
            return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
        }
    }

    func rank(of player: Player) -> Int {
        let total = player.totalPoints ?? player.points ?? 0
        return 1 + players.filter { ($0.totalPoints ?? $0.points ?? 0) > total }.count
    }

    func player(_ id: UUID?) -> Player? {
        players.first { $0.id == id }
    }

    /// With nobody set as seeker (e.g. testing alone), everyone seeks.
    func isSeeking(_ id: UUID) -> Bool {
        player(id)?.role == .seeker || !players.contains { $0.role == .seeker }
    }
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
