import XCTest
import SwiftUI
@testable import Rally

final class Character3DTests: XCTestCase {
    @MainActor func testGeneratedHumanPosesPaintClonesAndReopenEndToEnd() async throws {
        guard let existing = CharacterAsset.all().first(where: { $0.hasModel && $0.rigged }) else {
            throw XCTSkip("This end-to-end test uses an existing generated human; it never spends Tripo credits.")
        }
        let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: existing.server, rigged: true, attribution: existing.attribution)
        try asset.save()
        try FileManager.default.copyItem(at: existing.directory.appendingPathComponent("source.glb"), to: asset.directory.appendingPathComponent("source.glb"))
        defer { try? FileManager.default.removeItem(at: asset.directory) }
        let evidence = HouseStore.documents.appendingPathComponent("Verification/character-gameplay", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let model = Character3DModel(asset: asset)
        window.rootViewController = UIHostingController(rootView: CharacterWebView(model: model).frame(width: 420, height: 520))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitForViewer(model)
        let view = try XCTUnwrap(model.webView)
        let initial = try await view.callAsyncJavaScript("return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let originalJoints = try XCTUnwrap(initial?["joints"] as? [[String: Any]])
        XCTAssertGreaterThan(originalJoints.count, 30)
        XCTAssertFalse(model.bones.contains(where: { $0.displayName.lowercased().contains("mixamorig") }))
        XCTAssertEqual(initial?["humanoid"] as? Bool, true)
        var standJoints: [[String: Any]] = []
        var qualityReports: [[String: Any]] = []
        for pose in CharacterPoseChoice.pages.flatMap({ $0 }) {
            model.selectPose(pose.id)
            try await Task.sleep(for: .milliseconds(120))
            let result = try await view.callAsyncJavaScript("return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(result?["finite"] as? Bool, true, pose.name)
            XCTAssertEqual(result?["preset"] as? String, pose.id)
            let joints = try XCTUnwrap(result?["joints"] as? [[String: Any]])
            qualityReports.append(["pose": pose.id, "quality": result?["quality"] ?? [:]])
            if pose.id == "stand" { standJoints = joints }
            for (before, after) in zip(originalJoints, joints) {
                XCTAssertEqual(before["length"] as? Double, after["length"] as? Double, "Bone lengths must not change in \(pose.name)")
                if let parentName = before["parent"] as? String,
                   let originalParent = originalJoints.first(where: { $0["name"] as? String == parentName }),
                   let posedParent = joints.first(where: { $0["name"] as? String == parentName }) {
                    func distance(_ first: [String: Any], _ second: [String: Any]) throws -> Double {
                        let start = try XCTUnwrap(first["position"] as? [Double])
                        let end = try XCTUnwrap(second["position"] as? [Double])
                        return sqrt(zip(start, end).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) })
                    }
                    XCTAssertEqual(try distance(before, originalParent), try distance(after, posedParent), accuracy: 0.0001)
                }
            }
            let screenshot = try await view.callAsyncJavaScript("return window.characterViewer.screenshot()", arguments: [:], in: nil, contentWorld: .page) as? String
            try XCTUnwrap(screenshot.flatMap { Data(base64Encoded: $0) }).write(to: evidence.appendingPathComponent("pose-\(pose.id).png"))
        }
        try JSONSerialization.data(withJSONObject: qualityReports, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("pose-quality.json"))
        let originalHand = try XCTUnwrap(originalJoints.first(where: { ($0["name"] as? String)?.hasSuffix("RightHand") == true })?["position"] as? [Double])
        let standingHand = try XCTUnwrap(standJoints.first(where: { ($0["name"] as? String)?.hasSuffix("RightHand") == true })?["position"] as? [Double])
        let displacement = zip(originalHand, standingHand).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) }
        XCTAssertGreaterThan(displacement, 0.01, "A valid pose must actually move the human's joints.")
        model.selectPose("stand")
        try await Task.sleep(for: .milliseconds(150))
        let paint = try await view.callAsyncJavaScript("const before = window.characterViewer.diagnostics().paint; let painted = false; for (const point of [[0,0],[-0.15,0],[0.15,0],[0,0.2]]) { if (window.characterViewer.paintAt(point[0], point[1], { color: '#f03a35', brush: 0.09, opacity: 1 })) { painted = true; break; } } return { before, after: window.characterViewer.diagnostics().paint, painted };", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(paint?["painted"] as? Bool, true)
        XCTAssertNotEqual(paint?["before"] as? NSNumber, paint?["after"] as? NSNumber)
        let undo = try await view.callAsyncJavaScript("window.characterViewer.action('undo'); return window.characterViewer.diagnostics().paint", arguments: [:], in: nil, contentWorld: .page) as? NSNumber
        XCTAssertEqual(undo, paint?["before"] as? NSNumber)
        let redo = try await view.callAsyncJavaScript("window.characterViewer.action('redo'); return window.characterViewer.diagnostics().paint", arguments: [:], in: nil, contentWorld: .page) as? NSNumber
        XCTAssertEqual(redo, paint?["after"] as? NSNumber)
        var turnImages: [Data] = []
        for yaw in [0.0, 180.0] {
            model.yaw = yaw
            try await Task.sleep(for: .milliseconds(150))
            let screenshot = try await view.callAsyncJavaScript("window.characterViewer.diagnostics(); return window.characterViewer.screenshot()", arguments: [:], in: nil, contentWorld: .page) as? String
            let data = try XCTUnwrap(screenshot.flatMap { Data(base64Encoded: $0) })
            turnImages.append(data)
            try data.write(to: evidence.appendingPathComponent("painted-turn-\(Int(yaw)).png"))
        }
        XCTAssertNotEqual(turnImages[0], turnImages[1], "Turning the character must show different 3D surfaces.")
        model.yaw = 0
        try await Task.sleep(for: .milliseconds(150))
        let cloned = try await view.callAsyncJavaScript("window.characterViewer.action('clone'); window.characterViewer.action('clone'); return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        model.export()
        for _ in 0..<300 {
            if model.saved || model.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.saved)
        let stored = try JSONDecoder().decode(CharacterAsset.self, from: Data(contentsOf: asset.directory.appendingPathComponent("character.json")))
        let reopened = Character3DModel(asset: stored)
        window.rootViewController = UIHostingController(rootView: CharacterWebView(model: reopened).frame(width: 420, height: 520))
        try await waitForViewer(reopened)
        let restored = try await reopened.webView?.callAsyncJavaScript("return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(restored?["paint"] as? NSNumber, paint?["after"] as? NSNumber)
        XCTAssertEqual(restored?["clones"] as? Int, 2)
        XCTAssertEqual(restored?["preset"] as? String, "stand")
        let expectedBounds = try XCTUnwrap(cloned?["cloneBounds"] as? [[String: [Double]]])
        let actualBounds = try XCTUnwrap(restored?["cloneBounds"] as? [[String: [Double]]])
        XCTAssertEqual(expectedBounds.count, actualBounds.count)
        for (expected, actual) in zip(expectedBounds, actualBounds) {
            for key in ["min", "max"] {
                for (before, after) in zip(try XCTUnwrap(expected[key]), try XCTUnwrap(actual[key])) {
                    XCTAssertEqual(before, after, accuracy: 0.00001, "Reopening must not move frozen clones.")
                }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent("paint.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.directory.appendingPathComponent("scene.json").path))
        let practice = try await reopened.webView?.callAsyncJavaScript("const bounds = window.characterViewer.diagnostics().bounds; const horizontal = (bounds.min[0] + bounds.max[0]) / 2; let hit = false; for (const fraction of [0.6, 0.5, 0.7]) { const origin = [horizontal, bounds.min[1] + (bounds.max[1] - bounds.min[1]) * fraction, bounds.min[2] - 2]; if (window.characterViewer.practiceTag(origin, [0,0,1])) { hit = true; break; } } return {hit, duplicate: window.characterViewer.practiceTag([horizontal, 1, -3], [0,0,1])};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(practice?["hit"] as? Bool, true, "Practice must hit actual skinned triangles, not just a placeholder.")
        XCTAssertEqual(practice?["duplicate"] as? Bool, false, "Finding one body must eliminate its clones too.")
        _ = try await reopened.webView?.callAsyncJavaScript("window.characterViewer.visibility([], true); window.characterViewer.action('clearClones')", arguments: [:], in: nil, contentWorld: .page)
        for form in ["rounded", "blocky"] {
            reopened.editing.form = form
            reopened.selectPose("tpose")
            try await Task.sleep(for: .milliseconds(350))
            let result = try await reopened.webView?.callAsyncJavaScript("return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(result?["finite"] as? Bool, true)
            let screenshot = try await reopened.webView?.callAsyncJavaScript("return window.characterViewer.screenshot()", arguments: [:], in: nil, contentWorld: .page) as? String
            try XCTUnwrap(screenshot.flatMap { Data(base64Encoded: $0) }).write(to: evidence.appendingPathComponent("form-\(form).png"))
        }
    }

    @MainActor private func waitForViewer(_ model: Character3DModel) async throws {
        for _ in 0..<300 {
            if model.viewerLoaded || model.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.viewerLoaded)
    }

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
