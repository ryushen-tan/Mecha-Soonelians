import ARKit
import RoomPlan

/// On-device storage. Everything lives in Documents so it shows up in the Files app.
///
///     Documents/House/house.usdz            merged RoomPlan model
///     Documents/House/structure.json        merged RoomPlan data (walls, doors, objects)
///     Documents/House/rooms/room-N.json     each room as scanned
///     Documents/House/worldmap.arexperience ARKit world map, for relocalizing later
///     Documents/House/test-cubes.json       cubes dropped in the map test, in house coordinates
enum HouseStore {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var houseDir: URL { documents.appendingPathComponent("House", isDirectory: true) }
    static var modelURL: URL { houseDir.appendingPathComponent("house.usdz") }
    static var structureURL: URL { houseDir.appendingPathComponent("structure.json") }
    static var worldMapURL: URL { houseDir.appendingPathComponent("worldmap.arexperience") }
    static var testCubesURL: URL { houseDir.appendingPathComponent("test-cubes.json") }

    static var hasHouse: Bool { FileManager.default.fileExists(atPath: worldMapURL.path) }

    static func saveHouse(structure: CapturedStructure, rooms: [CapturedRoom], worldMap: ARWorldMap) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: houseDir)
        let roomsDir = houseDir.appendingPathComponent("rooms", isDirectory: true)
        try fm.createDirectory(at: roomsDir, withIntermediateDirectories: true)

        try structure.export(to: modelURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(structure).write(to: structureURL)
        for (index, room) in rooms.enumerated() {
            try encoder.encode(room).write(to: roomsDir.appendingPathComponent("room-\(index + 1).json"))
        }

        let mapData = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        try mapData.write(to: worldMapURL)
    }

    static func loadWorldMap() throws -> ARWorldMap {
        let data = try Data(contentsOf: worldMapURL)
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return map
    }

    static func loadStructure() throws -> CapturedStructure {
        try JSONDecoder().decode(CapturedStructure.self, from: Data(contentsOf: structureURL))
    }

    /// Each cube is a 4x4 transform stored as 16 floats, column by column.
    static func loadTestCubes() -> [simd_float4x4] {
        guard let data = try? Data(contentsOf: testCubesURL),
              let cubes = try? JSONDecoder().decode([[Float]].self, from: data) else { return [] }
        return cubes.compactMap { m in
            guard m.count == 16 else { return nil }
            return simd_float4x4((0..<4).map { SIMD4<Float>(m[$0 * 4 ..< $0 * 4 + 4]) })
        }
    }

    static func saveTestCubes(_ cubes: [simd_float4x4]) throws {
        let floats = cubes.map { t in
            [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
        try JSONEncoder().encode(floats).write(to: testCubesURL)
    }
}
