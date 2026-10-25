import ARKit
import CryptoKit
import RoomPlan

struct SavedRoom: Identifiable {
    struct Details: Codable {
        let id: String
        let name: String
        let createdAt: Date
    }
    let id: String
    let name: String
    let directory: URL
    let isBundled: Bool
    var modelURL: URL { directory.appendingPathComponent("house.usdz") }
    var structureURL: URL { directory.appendingPathComponent("structure.json") }
    var worldMapURL: URL { directory.appendingPathComponent("worldmap.arexperience") }
    var isAvailable: Bool {
        [modelURL, structureURL, worldMapURL].allSatisfy {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    func validate() throws {
        guard isAvailable else { throw CocoaError(.fileReadCorruptFile) }
        let mapData = try Data(contentsOf: worldMapURL)
        #if targetEnvironment(simulator)
        // Simulator can preview interiors, but its ARWorldMap class cannot decode secure archives.
        // Check the archive container here; physical devices fully decode it below.
        let archive = try PropertyListSerialization.propertyList(from: mapData, format: nil) as? [String: Any]
        guard archive?["$archiver"] as? String == "NSKeyedArchiver",
              let objects = archive?["$objects"] as? [Any],
              objects.contains(where: { ($0 as? [String: Any])?["$classname"] as? String == "ARWorldMap" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        #else
        guard try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: mapData) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        #endif
        _ = try JSONDecoder().decode(CapturedStructure.self, from: Data(contentsOf: structureURL))
    }
}

/// On-device storage. Everything lives in Documents so it shows up in the Files app.
///
///     Documents/SavedRooms/<UUID>/house.usdz            merged RoomPlan model
///     Documents/SavedRooms/<UUID>/structure.json        walls, doors, objects
///     Documents/SavedRooms/<UUID>/rooms/room-N.json     each room as scanned
///     Documents/SavedRooms/<UUID>/worldmap.arexperience ARKit relocalization map
///     Documents/SavedRooms/<UUID>/room-info.json        name and creation date
/// Old Documents/House scans are listed without moving or deleting them.
enum HouseStore {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var houseDir: URL { documents.appendingPathComponent("House", isDirectory: true) }
    static var modelURL: URL { houseDir.appendingPathComponent("house.usdz") }
    static var structureURL: URL { houseDir.appendingPathComponent("structure.json") }
    static var worldMapURL: URL { houseDir.appendingPathComponent("worldmap.arexperience") }
    static var testCubesURL: URL { houseDir.appendingPathComponent("test-cubes.json") }
    static var libraryDir: URL { documents.appendingPathComponent("SavedRooms", isDirectory: true) }
    static let selectedRoomKey = "selectedPlayRoomID"

    static var hasHouse: Bool {
        !savedRooms().isEmpty || SavedRoom(id: "legacy", name: "Previous house scan", directory: houseDir, isBundled: false).isAvailable
    }

    // MARK: The house that ships inside the app

    /// The scan in the repository's House folder, copied into every build, so no phone has to scan,
    /// upload or download it.
    static var bundledDir: URL? { Bundle.main.url(forResource: "House", withExtension: nil) }
    static var bundledWorldMapURL: URL? { bundledDir?.appendingPathComponent("worldmap.arexperience") }
    static var bundledStructureURL: URL? { bundledDir?.appendingPathComponent("structure.json") }

    /// Names the bundled scan (the start of its world map's SHA-256), so a game can tell whether every
    /// phone has the same one.
    static let bundledID: String? = bundledWorldMapURL.flatMap(fingerprint)

    /// Repository scans travel with each build, including their AR relocalization maps.
    /// Keep the original ID and default for existing games and older app versions.
    static let bundledRooms: [SavedRoom] = {
        guard let directory = bundledDir else { return [] }
        let original = SavedRoom(id: "bundled", name: "Original play room", directory: directory, isBundled: true)
        let library = savedRooms(in: directory.appendingPathComponent("SavedRooms"), isBundled: true)
        return (original.isAvailable ? [original] : []) + library
    }()

    /// Hash large maps once per launch, rather than on every room-picker render.
    private static let bundledMapIDs: [String: String] = Dictionary(uniqueKeysWithValues:
        bundledRooms.compactMap { room in fingerprint(room.worldMapURL).map { (room.id, $0) } })

    static func bundledMapID(for room: SavedRoom) -> String? {
        room.isBundled ? bundledMapIDs[room.id] : nil
    }

    static func bundledRoom(withMapID id: String) -> SavedRoom? {
        bundledRooms.first { bundledMapIDs[$0.id] == id }
    }

    private static func fingerprint(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    enum Source { case bundled, custom, none }

    static func savedRooms(in directory: URL = libraryDir, isBundled: Bool = false) -> [SavedRoom] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder -> (SavedRoom.Details, SavedRoom)? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("room-info.json")),
                  let details = try? JSONDecoder().decode(SavedRoom.Details.self, from: data),
                  UUID(uuidString: details.id) != nil, details.id == folder.lastPathComponent else { return nil }
            let room = SavedRoom(id: details.id, name: details.name, directory: folder, isBundled: isBundled)
            return room.isAvailable ? (details, room) : nil
        }.sorted { $0.0.createdAt > $1.0.createdAt }.map { $0.1 }
    }

    static var rooms: [SavedRoom] {
        // A scan backed up from this phone retains its ID and selection, but uses the included
        // copy so every phone can resolve it without uploading the same large map again.
        let includedIDs = Set(bundledRooms.map(\.id))
        var result = savedRooms().filter { !includedIDs.contains($0.id) }
        let legacy = SavedRoom(id: "legacy", name: "Previous house scan", directory: houseDir, isBundled: false)
        if legacy.isAvailable { result.append(legacy) }
        return result + bundledRooms
    }

    static var selectedRoom: SavedRoom? {
        let available = rooms
        if let id = UserDefaults.standard.string(forKey: selectedRoomKey) {
            // A missing selection must be repaired explicitly, not replaced with a different physical room.
            return available.first { $0.id == id }
        }
        return available.first { $0.id == "legacy" } ?? available.first { $0.isBundled }
    }

    static func select(_ room: SavedRoom) throws {
        try room.validate()
        UserDefaults.standard.set(room.id, forKey: selectedRoomKey)
    }

    /// The explicit host selection controls both the local AR map and the multiplayer upload.
    static var source: Source {
        guard let room = selectedRoom else { return .none }
        return room.isBundled ? .bundled : .custom
    }

    static var activeWorldMapURL: URL { selectedRoom?.worldMapURL ?? worldMapURL }
    static var activeStructureURL: URL { selectedRoom?.structureURL ?? structureURL }

    static func saveHouse(structure: CapturedStructure, rooms: [CapturedRoom], worldMap: ARWorldMap,
                          name: String = "My room") throws {
        let saved = try saveRoom(name: name) { directory in
            let roomsDir = directory.appendingPathComponent("rooms", isDirectory: true)
            try FileManager.default.createDirectory(at: roomsDir, withIntermediateDirectories: true)
            try structure.export(to: directory.appendingPathComponent("house.usdz"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(structure).write(to: directory.appendingPathComponent("structure.json"))
            for (index, room) in rooms.enumerated() {
                try encoder.encode(room).write(to: roomsDir.appendingPathComponent("room-\(index + 1).json"))
            }
            let mapData = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            try mapData.write(to: directory.appendingPathComponent("worldmap.arexperience"))
        }
        try select(saved)
    }

    /// Publish a complete scan atomically; failed scans never overwrite a saved room.
    static func saveRoom(name: String, in root: URL = libraryDir,
                         write: (URL) throws -> Void) throws -> SavedRoom {
        let fm = FileManager.default
        let id = UUID().uuidString
        let staging = root.appendingPathComponent(".saving-" + id, isDirectory: true)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try write(staging)
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let details = SavedRoom.Details(id: id, name: cleanName.isEmpty ? "My room" : cleanName, createdAt: Date())
        let stagedRoom = SavedRoom(id: id, name: details.name, directory: staging, isBundled: false)
        try stagedRoom.validate()
        try JSONEncoder().encode(details).write(to: staging.appendingPathComponent("room-info.json"), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
        return SavedRoom(id: id, name: details.name, directory: destination, isBundled: false)
    }

    static func loadWorldMap() throws -> ARWorldMap {
        let data = try Data(contentsOf: activeWorldMapURL)
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return map
    }

    static func loadStructure() throws -> CapturedStructure {
        try JSONDecoder().decode(CapturedStructure.self, from: Data(contentsOf: activeStructureURL))
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
        try FileManager.default.createDirectory(at: houseDir, withIntermediateDirectories: true)
        let floats = cubes.map { t in
            [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
        try JSONEncoder().encode(floats).write(to: testCubesURL)
    }
}
