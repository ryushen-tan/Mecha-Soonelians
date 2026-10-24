import XCTest
import SwiftUI
@testable import Rally

final class Character3DTests: XCTestCase {
    func testServerURLRejectsCredentialsAndPublicHTTP() {
        for address in ["http://localhost:3001", "http://192.168.1.2:3001", "https://example.com"] {
            XCTAssertNoThrow(try CharacterAPI(address: address, accessToken: ""))
        }
        for address in ["http://example.com", "https://key@example.com", "https://example.com?token=a", "file:///tmp", "http://192.168.1.999", "http://192.168.1.2.example.com"] {
            XCTAssertThrowsError(try CharacterAPI(address: address, accessToken: ""))
        }
    }

    @MainActor func testRealWebViewerLoadsSkinningRotatesJointAndExportsGLB() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-rig", withExtension: "glb"))
        let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: "http://localhost:3001")
        try asset.save()
        defer { try? FileManager.default.removeItem(at: asset.directory) }
        let model = Character3DModel(asset: asset)
        model.modelData = try Data(contentsOf: fixture)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CharacterWebView(model: model).frame(width: 360, height: 400))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<200 {
            if model.viewerLoaded || model.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.viewerLoaded, "Bundled viewer must actually load the GLB, not just show a placeholder.")
        XCTAssertEqual(model.bones.count, 2)
        let tip = try XCTUnwrap(model.bones.first { $0.name == "TestTip" })
        model.selectedBone = tip.id
        model.selectedAxis = 2
        model.setAngle(45)
        model.yaw = 60
        try await Task.sleep(for: .milliseconds(300))
        model.export()
        for _ in 0..<200 {
            if model.saved || model.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.saved)
        let data = try Data(contentsOf: asset.directory.appendingPathComponent("character.glb"))
        XCTAssertEqual(data.prefix(4), Data("glTF".utf8))
        let jsonLength = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self))) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + jsonLength))) as? [String: Any])
        let skins = try XCTUnwrap(json["skins"] as? [[String: Any]])
        XCTAssertFalse(skins.isEmpty, "Export must preserve the skin, not flatten the mesh.")
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let tipNode = try XCTUnwrap(nodes.first { $0["name"] as? String == "TestTip" })
        let rotation = try XCTUnwrap(tipNode["rotation"] as? [Double])
        XCTAssertEqual(rotation[2], sin(.pi / 8), accuracy: 0.001)
        let saved = try JSONDecoder().decode(CharacterAsset.self, from: Data(contentsOf: asset.directory.appendingPathComponent("character.json")))
        XCTAssertEqual(saved.yaw, 60)
        XCTAssertEqual(saved.angles[String(tip.id)]?[2], 45)
    }
}
