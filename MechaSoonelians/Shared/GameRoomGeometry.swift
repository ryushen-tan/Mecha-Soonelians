import Foundation
import RoomPlan
import simd

struct GameRoomGeometry: Codable {
    struct Surface: Codable {
        let id: String
        let kind: String
        let dimensions: [Float]
        let transform: [Float]?
        let color: String?
        var holes: [[Float]]? = nil
        var position: [Float]? = nil
    }

    let name: String
    let source: String
    let surfaces: [Surface]

    static func scannedHouse() -> GameRoomGeometry? {
        guard let data = try? Data(contentsOf: HouseStore.structureURL),
              let structure = try? JSONDecoder().decode(CapturedStructure.self, from: data) else { return nil }
        var surfaces: [Surface] = []
        for room in structure.rooms {
            for wall in room.walls {
                let openings = room.doors + room.openings + room.windows
                let inverse = wall.transform.inverse
                let holes = openings.compactMap { opening -> [Float]? in
                    let local = inverse * opening.transform.columns.3
                    guard abs(local.z) < 0.2, abs(local.x) < wall.dimensions.x / 2 + 0.05 else { return nil }
                    return [local.x, local.y, opening.dimensions.x, opening.dimensions.y]
                }
                surfaces.append(Surface(id: wall.identifier.uuidString, kind: "wall",
                    dimensions: [wall.dimensions.x, wall.dimensions.y, max(0.06, wall.dimensions.z)],
                    transform: flatten(wall.transform), color: "#d2d7c0", holes: holes))
            }
            for floor in room.floors {
                surfaces.append(Surface(id: floor.identifier.uuidString, kind: "floor",
                    dimensions: [floor.dimensions.x, floor.dimensions.y, max(0.04, floor.dimensions.z)],
                    transform: flatten(floor.transform), color: "#bbac8e"))
            }
            for object in room.objects {
                surfaces.append(Surface(id: object.identifier.uuidString, kind: "object",
                    dimensions: [object.dimensions.x, object.dimensions.y, object.dimensions.z],
                    transform: flatten(object.transform), color: "#8f9e95"))
            }
            for window in room.windows {
                surfaces.append(Surface(id: window.identifier.uuidString, kind: "window", dimensions: [window.dimensions.x, window.dimensions.y, 0.02],
                    transform: flatten(window.transform), color: "#b6d7e2"))
            }
        }
        return GameRoomGeometry(name: "Your scanned house", source: "roomplan", surfaces: surfaces)
    }

    private static func flatten(_ matrix: simd_float4x4) -> [Float] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}
