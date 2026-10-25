import XCTest
import SwiftUI
@testable import MechaSoonelians

final class PlayRoomTests: XCTestCase {
    @MainActor func testRepositoryRoomsHaveDistinctMapsAndPreserveSelections() throws {
        let previous = UserDefaults.standard.string(forKey: HouseStore.selectedRoomKey)
        defer { UserDefaults.standard.set(previous, forKey: HouseStore.selectedRoomKey) }
        let original = try XCTUnwrap(HouseStore.bundledRooms.first { $0.id == "bundled" })
        let main = try XCTUnwrap(HouseStore.bundledRooms.first { $0.name == "Main" })
        try original.validate()
        try main.validate()
        let originalID = try XCTUnwrap(HouseStore.bundledMapID(for: original))
        let mainID = try XCTUnwrap(HouseStore.bundledMapID(for: main))
        XCTAssertEqual(originalID, HouseStore.bundledID)
        XCTAssertNotEqual(originalID, mainID)
        XCTAssertEqual(HouseStore.bundledRoom(withMapID: mainID)?.directory, main.directory)
        XCTAssertEqual(HouseStore.bundledRoom(withMapID: originalID)?.directory, original.directory)
        XCTAssertNil(HouseStore.bundledRoom(withMapID: "missing-map"))
        XCTAssertEqual(HouseStore.rooms.filter { $0.id == main.id }.count, 1,
                       "A phone's own backed-up scan must not appear twice.")
        try HouseStore.select(main)
        XCTAssertEqual(HouseStore.selectedRoom?.id, main.id)
        XCTAssertEqual(HouseStore.source, .bundled)
        XCTAssertEqual(HouseStore.activeWorldMapURL, main.worldMapURL)
        XCTAssertEqual(HouseStore.activeStructureURL, main.structureURL)
        let session = GameSession(connection: GameConnection(server: URL(string: "https://no-network.invalid")!,
            code: "123456", memberID: UUID().uuidString, token: "test", isHost: true), name: "Host", avatar: 0)
        XCTAssertEqual(session.mapURL, main.worldMapURL)
        XCTAssertEqual(session.structureURL, main.structureURL)
        XCTAssertTrue(session.hasMap)
    }

    private func copyBundledRoom(to destination: URL) throws {
        let source = try XCTUnwrap(HouseStore.bundledDir)
        for file in ["house.usdz", "structure.json", "worldmap.arexperience"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(file),
                                            to: destination.appendingPathComponent(file))
        }
    }

    func testMultipleScansPersistAndFailedSavePreservesExistingRooms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try HouseStore.saveRoom(name: "Living room", in: root, write: copyBundledRoom)
        let second = try HouseStore.saveRoom(name: "Bedroom", in: root, write: copyBundledRoom)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(HouseStore.savedRooms(in: root).map(\.name)), ["Living room", "Bedroom"])
        let originalMap = try Data(contentsOf: first.worldMapURL)
        XCTAssertThrowsError(try HouseStore.saveRoom(name: "Interrupted scan", in: root) { directory in
            try Data("incomplete".utf8).write(to: directory.appendingPathComponent("structure.json"))
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertThrowsError(try HouseStore.saveRoom(name: "Corrupt scan", in: root) { directory in
            for file in ["house.usdz", "structure.json", "worldmap.arexperience"] {
                try Data("invalid".utf8).write(to: directory.appendingPathComponent(file))
            }
        })
        XCTAssertEqual(HouseStore.savedRooms(in: root).count, 2)
        XCTAssertEqual(try Data(contentsOf: first.worldMapURL), originalMap)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2,
                       "Failed scan staging folders must not remain in the library.")
    }

    @MainActor func testSelectionControlsHostMapAndMissingSelectionDoesNotFallBack() throws {
        let previous = UserDefaults.standard.string(forKey: HouseStore.selectedRoomKey)
        let saved = try HouseStore.saveRoom(name: "Test interior", write: copyBundledRoom)
        defer {
            UserDefaults.standard.set(previous, forKey: HouseStore.selectedRoomKey)
            try? FileManager.default.removeItem(at: saved.directory)
        }
        try HouseStore.select(saved)
        XCTAssertEqual(HouseStore.selectedRoom?.id, saved.id)
        XCTAssertEqual(HouseStore.source, .custom)
        XCTAssertEqual(HouseStore.activeWorldMapURL.resolvingSymlinksInPath(), saved.worldMapURL.resolvingSymlinksInPath())
        XCTAssertEqual(HouseStore.activeStructureURL.resolvingSymlinksInPath(), saved.structureURL.resolvingSymlinksInPath())
        let session = GameSession(connection: GameConnection(server: URL(string: "https://no-network.invalid")!,
            code: "123456", memberID: UUID().uuidString, token: "test", isHost: true), name: "Host", avatar: 0)
        XCTAssertEqual(session.mapURL.resolvingSymlinksInPath(), saved.worldMapURL.resolvingSymlinksInPath())
        XCTAssertEqual(session.structureURL.resolvingSymlinksInPath(), saved.structureURL.resolvingSymlinksInPath())
        XCTAssertTrue(session.hasMap)
        XCTAssertEqual(GameRoomGeometry.scannedHouse()?.name, saved.name)
        let bundled = try XCTUnwrap(HouseStore.rooms.first { $0.isBundled })
        try HouseStore.select(bundled)
        XCTAssertEqual(HouseStore.source, .bundled)
        XCTAssertEqual(HouseStore.activeWorldMapURL, HouseStore.bundledWorldMapURL)
        UserDefaults.standard.set(UUID().uuidString, forKey: HouseStore.selectedRoomKey)
        XCTAssertNil(HouseStore.selectedRoom)
        XCTAssertEqual(HouseStore.source, .none)
    }

    @MainActor func testRoomPickerRendersInteriorAtPhoneAndTabletWidths() async throws {
        let previous = UserDefaults.standard.string(forKey: HouseStore.selectedRoomKey)
        let bundled = try XCTUnwrap(HouseStore.rooms.first { $0.isBundled })
        try HouseStore.select(bundled)
        defer { UserDefaults.standard.set(previous, forKey: HouseStore.selectedRoomKey) }
        for width in [320.0, 375, 414, 768] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            let host = UIHostingController(rootView: PlayRoomPicker(onSelection: {})
                .environmentObject(JellyAudio()).frame(width: width, height: 900))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .seconds(1))
            let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Room picker \(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    @MainActor func testInteriorPreviewOnlyEnablesSelectionAfterModelLoads() async throws {
        let url = try XCTUnwrap(HouseStore.bundledDir?.appendingPathComponent("house.usdz"))
        var ready = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            RoomInteriorPreview(url: url, ready: Binding(get: { ready }, set: { ready = $0 }))
                .frame(width: 320, height: 280))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<50 where !ready { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(ready)
        ready = true
        window.rootViewController = UIHostingController(rootView:
            RoomInteriorPreview(url: URL(fileURLWithPath: "/missing-room.usdz"),
                ready: Binding(get: { ready }, set: { ready = $0 })).frame(width: 320, height: 280))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(ready, "A broken preview must not leave the previous room's action enabled.")
    }
}
