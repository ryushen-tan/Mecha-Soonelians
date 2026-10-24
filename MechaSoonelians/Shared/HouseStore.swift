import ARKit
import RoomPlan

/// On-device storage. Everything lives in Documents so it shows up in the Files app.
///
///     Documents/House/house.usdz            merged RoomPlan model
///     Documents/House/structure.json        merged RoomPlan data (walls, doors, objects)
///     Documents/House/rooms/room-N.json     each room as scanned
///     Documents/House/worldmap.arexperience ARKit world map, for relocalizing later
enum HouseStore {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var houseDir: URL { documents.appendingPathComponent("House", isDirectory: true) }
    static var modelURL: URL { houseDir.appendingPathComponent("house.usdz") }
    static var structureURL: URL { houseDir.appendingPathComponent("structure.json") }
    static var worldMapURL: URL { houseDir.appendingPathComponent("worldmap.arexperience") }

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
}
