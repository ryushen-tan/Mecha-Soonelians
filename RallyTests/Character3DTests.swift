import XCTest
import SwiftUI
import WebKit
@testable import Rally

private final class CharacterSetupMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "character-setup-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            let data: Data
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Rig"), "1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer proxy-test-token")
                let id = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Request-ID"))
                data = try JSONSerialization.data(withJSONObject: ["id": id, "status": "ready", "stage": "ready", "progress": 100, "rigged": true, "credits": 0])
            } else {
                XCTAssertTrue(url.path.hasSuffix("/model"))
                let fixture = try XCTUnwrap(Bundle(for: Character3DTests.self).url(forResource: "test-rig", withExtension: "glb"))
                data = try Data(contentsOf: fixture)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class Character3DTests: XCTestCase {
    @MainActor func testPersonalCaptureAutomaticallyRequestsRiggingAndPersistsForRelaunch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CharacterSetupMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let previous = UserDefaults.standard.string(forKey: CharacterProfile.preferenceKey)
        let model = Character3DModel(session: session)
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 20)).image { _ in }.pngData())
        model.generate(png: png, address: "https://character-setup-test.invalid", token: "proxy-test-token", attribution: nil, asProfile: true)
        let asset = try XCTUnwrap(model.asset)
        defer {
            UserDefaults.standard.set(previous, forKey: CharacterProfile.preferenceKey)
            try? FileManager.default.removeItem(at: asset.directory)
        }
        XCTAssertEqual(UserDefaults.standard.string(forKey: CharacterProfile.preferenceKey), asset.id)
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.modelData)
        XCTAssertEqual(model.asset?.rigged, true)
        XCTAssertEqual(try Data(contentsOf: asset.directory.appendingPathComponent("input.png")), png)
        let receipt = try JSONDecoder().decode(CharacterJob.self, from: Data(contentsOf: asset.directory.appendingPathComponent("generation.json")))
        XCTAssertTrue(receipt.rigged)
        let loaded = try XCTUnwrap(CharacterAsset.all().first { $0.id == asset.id })
        XCTAssertTrue(loaded.rigged)
        let reopened = Character3DModel(asset: loaded, session: session)
        XCTAssertNotNil(reopened.modelData)
        XCTAssertFalse(reopened.busy)
    }

    func testPersonalCharacterSelectionAndBodyValidation() throws {
        let suite = "character-profile-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: "https://example.invalid")
        CharacterProfile.remember(pending, defaults: defaults)
        XCTAssertEqual(CharacterProfile.candidate(assets: [pending], defaults: defaults)?.id, pending.id)
        XCTAssertNil(CharacterProfile.candidate(assets: [], defaults: defaults))
        let pose = CharacterBodyArchive.Pose(id: "stand", name: "Stand", icon: "figure.stand")
        let info = CharacterBodyArchive.Info(vertexCount: 3, triangleCount: 1, poses: [pose])
        var bytes = Data()
        for value: Float in [0, 0, 1, 0, 0, 1] { var bits = value.bitPattern.littleEndian; bytes.append(Data(bytes: &bits, count: 4)) }
        for value: UInt32 in [0, 1, 2] { var bits = value.littleEndian; bytes.append(Data(bytes: &bits, count: 4)) }
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1.75, 0] { var bits = value.bitPattern.littleEndian; bytes.append(Data(bytes: &bits, count: 4)) }
        XCTAssertTrue(CharacterBodyArchive(info: info, data: bytes).isValid)
        XCTAssertFalse(CharacterBodyArchive(info: info, data: bytes.dropLast()).isValid)
        var invalidIndex = bytes
        var index: UInt32 = 3
        invalidIndex.replaceSubrange(24..<28, with: Data(bytes: &index, count: 4))
        XCTAssertFalse(CharacterBodyArchive(info: info, data: invalidIndex).isValid)
        var invalidPosition = bytes
        var nan = Float.nan.bitPattern
        invalidPosition.replaceSubrange(36..<40, with: Data(bytes: &nan, count: 4))
        XCTAssertFalse(CharacterBodyArchive(info: info, data: invalidPosition).isValid)
        XCTAssertFalse(CharacterBodyArchive(info: .init(vertexCount: Int.max, triangleCount: 1, poses: [pose]), data: bytes).isValid)
    }

    @MainActor func testPersonalCharacterBakesAllPosesAndReusesSavedModelWithoutNetwork() async throws {
        let existing = CharacterAsset.all().first { $0.hasModel && $0.rigged }
        let source = try XCTUnwrap(existing?.directory.appendingPathComponent("source.glb")
            ?? Bundle.main.url(forResource: "chameleon-base", withExtension: "glb", subdirectory: "CharacterViewer"))
        let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: "https://no-network.invalid", rigged: true)
        let previous = UserDefaults.standard.string(forKey: CharacterProfile.preferenceKey)
        try asset.save()
        try FileManager.default.copyItem(at: source, to: asset.directory.appendingPathComponent("source.glb"))
        defer {
            UserDefaults.standard.set(previous, forKey: CharacterProfile.preferenceKey)
            try? FileManager.default.removeItem(at: asset.directory)
        }
        let model = Character3DModel(asset: asset)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CharacterWebView(model: model).frame(width: 420, height: 520))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitForViewer(model)
        let view = try XCTUnwrap(model.webView)
        let result = try await view.callAsyncJavaScript("""
            const before = window.characterViewer.diagnostics();
            const result = window.characterViewer.bakeCharacter();
            const after = window.characterViewer.diagnostics();
            return {result, before, after};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let before = try XCTUnwrap(result?["before"] as? [String: Any])
        let after = try XCTUnwrap(result?["after"] as? [String: Any])
        XCTAssertEqual(before["placementPosition"] as? [Double], after["placementPosition"] as? [Double])
        XCTAssertEqual(before["placementRotation"] as? [Double], after["placementRotation"] as? [Double])
        try CharacterProfile.saveBody(try XCTUnwrap(result?["result"] as? [String: Any]), for: asset)
        let body = try XCTUnwrap(CharacterBodyArchive.load(from: asset.directory))
        XCTAssertEqual(body.info.poses.count, 15)
        XCTAssertTrue(body.info.poses.contains { $0.id == "crouch" })
        XCTAssertTrue(body.info.poses.contains { $0.id == "side" })
        let start = body.info.vertexCount * 8 + body.info.triangleCount * 12
        let poseSize = body.info.vertexCount * 12
        XCTAssertNotEqual(body.data[start..<(start + poseSize)], body.data[(start + poseSize)..<(start + poseSize * 2)])
        XCTAssertEqual(CharacterProfile.ready?.id, asset.id)
        let reopened = Character3DModel(asset: try XCTUnwrap(CharacterProfile.ready))
        XCTAssertEqual(reopened.modelData, model.modelData)
        XCTAssertFalse(reopened.busy)
        let sourceURL = asset.directory.appendingPathComponent("source.glb")
        let sourceData = try Data(contentsOf: sourceURL)
        try Data("broken model".utf8).write(to: sourceURL)
        XCTAssertNil(CharacterProfile.ready, "A corrupt model must not skip setup.")
        try sourceData.write(to: sourceURL)
        try FileManager.default.removeItem(at: asset.directory.appendingPathComponent("body.bin"))
        XCTAssertNil(CharacterProfile.ready, "Missing body data must return to setup instead of showing a broken avatar.")
    }

    @MainActor func testDirectMeshDraggingAxisRotationResizeAndSave() async throws {
        guard let existing = CharacterAsset.all().first(where: { $0.hasModel && $0.rigged }) else {
            throw XCTSkip("Direct manipulation uses the existing generated human, without paid jobs.")
        }
        var editing = CharacterEditingSettings()
        editing.preset = "stand"; editing.scale = 0.5; editing.room = true
        let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: existing.server, rigged: true, editing: editing)
        try asset.save()
        try FileManager.default.copyItem(at: existing.directory.appendingPathComponent("source.glb"), to: asset.directory.appendingPathComponent("source.glb"))
        defer { try? FileManager.default.removeItem(at: asset.directory) }
        let model = Character3DModel(asset: asset)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CharacterWebView(model: model).frame(width: 420, height: 520))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitForViewer(model)
        try await Task.sleep(for: .milliseconds(250))
        let view = try XCTUnwrap(model.webView)
        let dragged = try await view.callAsyncJavaScript("""
            const viewer = window.characterViewer, canvas = document.querySelector('canvas');
            const before = viewer.diagnostics(), center = before.manipulation.center, rect = canvas.getBoundingClientRect();
            const fire = (type, x, y, id = 91) => canvas.dispatchEvent(new PointerEvent(type, {bubbles:true, cancelable:true,
              pointerId:id, pointerType:'touch', button: type === 'pointermove' ? -1 : 0,
              clientX:rect.left + (x + 1) / 2 * rect.width, clientY:rect.top + (1 - y) / 2 * rect.height}));
            window.testMeshPointer = fire;
            fire('pointerdown', center[0], center[1]);
            const selected = viewer.diagnostics();
            for (let step = 1; step <= 5; step++) fire('pointermove', center[0] + step * 0.03, center[1] + step * 0.02);
            fire('pointerup', center[0] + 0.15, center[1] + 0.1);
            const after = viewer.diagnostics();
            fire('pointerdown', after.manipulation.center[0], after.manipulation.center[1]);
            fire('pointermove', after.manipulation.center[0] - 0.1, after.manipulation.center[1]);
            fire('pointercancel', after.manipulation.center[0] - 0.1, after.manipulation.center[1]);
            const cancelled = viewer.diagnostics(), mid = cancelled.manipulation.center;
            fire('pointerdown', mid[0], mid[1], 92);
            fire('pointermove', mid[0] + 0.04, mid[1], 92);
            fire('pointerdown', mid[0] + 0.2, mid[1], 93);
            fire('pointermove', mid[0] - 0.1, mid[1], 92);
            fire('pointermove', mid[0] + 0.3, mid[1], 93);
            fire('pointerup', mid[0] - 0.1, mid[1], 92);
            fire('pointerup', mid[0] + 0.3, mid[1], 93);
            const pinched = viewer.diagnostics();
            viewer.action('inspect');
            return {before, selected, after, cancelled, pinched};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: [String: Any]]
        XCTAssertEqual((dragged?["selected"]?["manipulation"] as? [String: Any])?["selected"] as? Bool, true)
        XCTAssertNotEqual(dragged?["before"]?["placementPosition"] as? [Double], dragged?["after"]?["placementPosition"] as? [Double])
        XCTAssertEqual(dragged?["before"]?["cameraPosition"] as? [Double], dragged?["after"]?["cameraPosition"] as? [Double], "Dragging the person must not orbit the camera.")
        let afterDrag = try XCTUnwrap(dragged?["after"]?["placementPosition"] as? [Double])
        let cancelled = try XCTUnwrap(dragged?["cancelled"]?["placementPosition"] as? [Double])
        for (expected, actual) in zip(afterDrag, cancelled) { XCTAssertEqual(expected, actual, accuracy: 0.00001) }
        let pinched = try XCTUnwrap(dragged?["pinched"]?["placementPosition"] as? [Double])
        for (expected, actual) in zip(afterDrag, pinched) { XCTAssertEqual(expected, actual, accuracy: 0.00001) }
        XCTAssertLessThan(try XCTUnwrap(dragged?["pinched"]?["cameraDistance"] as? Double), try XCTUnwrap(dragged?["cancelled"]?["cameraDistance"] as? Double))
        model.editing.transformMode = "rotate"
        try await Task.sleep(for: .milliseconds(150))
        let rotated = try await view.callAsyncJavaScript("""
            const viewer = window.characterViewer, fire = window.testMeshPointer, rotations = [];
            for (const axis of ['X','Y','Z']) {
              const before = viewer.diagnostics();
              let picked = false;
              for (const point of before.manipulation.handles[axis]) {
                fire('pointerdown', point[0], point[1]);
                const selection = viewer.diagnostics().manipulation;
                if (selection.dragging && selection.axis === axis) {
                  const center = before.manipulation.center, dx = point[0] - center[0], dy = point[1] - center[1];
                  fire('pointermove', point[0] - dy * 0.5 + 0.025, point[1] + dx * 0.5 + 0.015);
                  fire('pointerup', point[0] - dy * 0.5 + 0.025, point[1] + dx * 0.5 + 0.015);
                  picked = true; break;
                }
                fire('pointercancel', point[0], point[1]);
              }
              rotations.push({axis,picked,before:before.placementRotation,after:viewer.diagnostics()});
            }
            return rotations;
            """, arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]]
        for rotation in try XCTUnwrap(rotated) {
            let axis = rotation["axis"] as? String ?? ""
            XCTAssertEqual(rotation["picked"] as? Bool, true, axis)
            let after = try XCTUnwrap(rotation["after"] as? [String: Any])
            XCTAssertNotEqual(rotation["before"] as? [Double], after["placementRotation"] as? [Double], axis)
            XCTAssertTrue(after["collision"] is NSNull, axis)
            XCTAssertEqual(try XCTUnwrap((after["surface"] as? [String: Any])?["gap"] as? Double), 0.006, accuracy: 0.00001)
        }
        model.editing.transformMode = "scale"
        try await Task.sleep(for: .milliseconds(150))
        let resized = try await view.callAsyncJavaScript("""
            const viewer = window.characterViewer, fire = window.testMeshPointer, before = viewer.diagnostics();
            const center = before.manipulation.center;
            fire('pointerdown', center[0] + 0.03, center[1] + 0.12);
            fire('pointermove', center[0] + 0.09, center[1] + 0.26);
            fire('pointerup', center[0] + 0.09, center[1] + 0.26);
            return {before,after:viewer.diagnostics()};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: [String: Any]]
        let scale = try XCTUnwrap(resized?["after"]?["placementScale"] as? [Double])
        XCTAssertNotEqual(scale, resized?["before"]?["placementScale"] as? [Double])
        XCTAssertEqual(scale[0], scale[1]); XCTAssertEqual(scale[1], scale[2])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.editing.scale, scale[0], accuracy: 0.00001)
        let rotation = model.editing.rotation
        model.lockPlacement()
        try await Task.sleep(for: .milliseconds(150))
        let locked = try await view.callAsyncJavaScript("return window.characterViewer.diagnostics().manipulation", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(locked?["selected"] as? Bool, false)
        XCTAssertEqual(locked?["axes"] as? [String], [])
        model.export()
        for _ in 0..<100 {
            if model.saved || model.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.error); XCTAssertTrue(model.saved)
        let stored = try JSONDecoder().decode(CharacterAsset.self, from: Data(contentsOf: asset.directory.appendingPathComponent("character.json")))
        XCTAssertEqual(stored.editing?.rotation, rotation)
        XCTAssertEqual(try XCTUnwrap(stored.editing?.scale), scale[0], accuracy: 0.00001)
        var wallEditing = CharacterEditingSettings()
        wallEditing.preset = "stand"; wallEditing.room = true
        wallEditing.position = [-2.6725407150526226, 0.6559999879687148, 0.45454769367638764]
        wallEditing.rotation = [0, 0.7071067775318448, 0, 0.7071067848412502]
        let wallAsset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: existing.server, rigged: true, editing: wallEditing)
        try wallAsset.save()
        try FileManager.default.copyItem(at: existing.directory.appendingPathComponent("source.glb"), to: wallAsset.directory.appendingPathComponent("source.glb"))
        defer { try? FileManager.default.removeItem(at: wallAsset.directory) }
        let wallModel = Character3DModel(asset: wallAsset)
        window.rootViewController = UIHostingController(rootView: CharacterWebView(model: wallModel).frame(width: 420, height: 520))
        try await waitForViewer(wallModel)
        try await Task.sleep(for: .milliseconds(200))
        let wallView = try XCTUnwrap(wallModel.webView)
        let sideways = try await wallView.callAsyncJavaScript("""
            const viewer = window.characterViewer, canvas = document.querySelector('canvas'), rect = canvas.getBoundingClientRect();
            viewer.action('roomView');
            const body = viewer.diagnostics().bounds, middle = body.min.map((value, axis) => (value + body.max[axis]) / 2);
            viewer.lookAt(middle, [middle[0], middle[1] + 0.4, middle[2] - 3]);
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            const before = viewer.diagnostics(), center = before.manipulation.center;
            const fire = (type,x) => canvas.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:94,pointerType:'touch',
              button:type==='pointermove'?-1:0,clientX:rect.left+(x+1)/2*rect.width,clientY:rect.top+(1-center[1])/2*rect.height}));
            fire('pointerdown',center[0]);
            const selected = viewer.diagnostics().manipulation;
            for(let step=1;step<=5;step++) fire('pointermove',center[0]-step*0.04);
            fire('pointerup',center[0]-0.2);
            return {before,selected,after:viewer.diagnostics()};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: [String: Any]]
        XCTAssertEqual((sideways?["before"]?["surface"] as? [String: Any])?["surface"] as? String, "left-wall")
        XCTAssertEqual(sideways?["selected"]?["selected"] as? Bool, true)
        let originalPosition = try XCTUnwrap(sideways?["before"]?["placementPosition"] as? [Double])
        let movedPosition = try XCTUnwrap(sideways?["after"]?["placementPosition"] as? [Double])
        XCTAssertGreaterThan(movedPosition[0], originalPosition[0] + 0.05, "A pure sideways drag must move away from a side wall, not stay pinned to it.")
        XCTAssertEqual((sideways?["after"]?["surface"] as? [String: Any])?["surface"] as? String, "floor")
        XCTAssertTrue(sideways?["after"]?["collision"] is NSNull)
        XCTAssertEqual(try XCTUnwrap((sideways?["after"]?["surface"] as? [String: Any])?["gap"] as? Double),0.006,accuracy:0.00001)
    }

    @MainActor func testPaintingShowsAndSamplesTheWallBehindTheHuman() async throws {
        guard let existing = CharacterAsset.all().first(where: { $0.hasModel && $0.rigged }) else {
            throw XCTSkip("This renderer test uses an existing generated human without spending credits.")
        }
        let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: existing.server, rigged: true)
        try asset.save()
        try FileManager.default.copyItem(at: existing.directory.appendingPathComponent("source.glb"), to: asset.directory.appendingPathComponent("source.glb"))
        defer { try? FileManager.default.removeItem(at: asset.directory) }
        let model = Character3DModel(asset: asset)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CharacterWebView(model: model).frame(width: 420, height: 520))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitForViewer(model)
        model.selectPose("stand")
        model.editing.tool = "paint"
        model.preparePainting()
        for _ in 0..<100 {
            if model.editing.position.contains(where: { abs($0) > 0.1 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.editing.room)
        let view = try XCTUnwrap(model.webView)
        let result = try await view.callAsyncJavaScript("return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let background = try XCTUnwrap(result?["background"] as? [String: Any])
        XCTAssertEqual(background["wall"] as? String, "back-wall")
        let sampled = try await view.callAsyncJavaScript("return window.characterViewer.sampleAt(-0.8, 0.2)", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(sampled, "#d2d7c0", "The actual wall behind the human must be visible and sampleable.")
        let evidence = HouseStore.documents.appendingPathComponent("Verification/character-gameplay", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let screenshot = try await view.callAsyncJavaScript("return window.characterViewer.screenshot()", arguments: [:], in: nil, contentWorld: .page) as? String
        try XCTUnwrap(screenshot.flatMap { Data(base64Encoded: $0) }).write(to: evidence.appendingPathComponent("paint-against-wall.png"))
        model.editing.position[0] += 0.2
        let deliberate = model.editing.position
        try await Task.sleep(for: .milliseconds(200))
        model.preparePainting()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.editing.position, deliberate, "Entering paint must not overwrite an intentional placement.")
        model.editing.scale = 0.3
        model.lockPlacement()
        try await Task.sleep(for: .milliseconds(250))
        let lockedPosition = model.editing.position
        let lockedPose = model.editing.preset
        model.selectPose("crouch")
        model.setAngle(30)
        XCTAssertEqual(model.editing.preset, lockedPose)
        XCTAssertTrue(model.angles.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        let zoom = try await view.callAsyncJavaScript("const before = window.characterViewer.diagnostics(); window.characterViewer.action('zoomIn'); window.characterViewer.action('zoomIn'); const after = window.characterViewer.diagnostics(); return { before, after };", arguments: [:], in: nil, contentWorld: .page) as? [String: [String: Any]]
        XCTAssertLessThan(try XCTUnwrap(zoom?["after"]?["cameraDistance"] as? Double), try XCTUnwrap(zoom?["before"]?["cameraDistance"] as? Double))
        XCTAssertEqual(model.editing.position, lockedPosition)
        XCTAssertEqual(model.editing.scale, 0.3)
        XCTAssertEqual(zoom?["after"]?["placementLocked"] as? Bool, true)
        model.unlockPlacement()
        model.selectPose("crouch")
        XCTAssertEqual(model.editing.preset, "crouch")
        try await Task.sleep(for: .milliseconds(250))
        model.selectPose("stand")
        try await Task.sleep(for: .milliseconds(350))
        let beforeMove = model.editing.position
        let dragged = try await dragBody(view, dx: 0.12, dy: 0)
        let moved = try XCTUnwrap(dragged["after"]?["placementPosition"] as? [Double])
        XCTAssertNotEqual(moved, beforeMove, "Dragging the unlocked body must move it.")
        let stale = try await view.callAsyncJavaScript("window.characterViewer.configure({position: old}, {}, 0, false, true, 0); return window.characterViewer.diagnostics()", arguments: ["old": beforeMove], in: nil, contentWorld: .page) as? [String: Any]
        for (actual, expected) in zip(try XCTUnwrap(stale?["placementPosition"] as? [Double]), moved) {
            XCTAssertEqual(actual, expected, accuracy: 0.00001, "A stale native update must not undo a drag.")
        }
        try await Task.sleep(for: .milliseconds(200))
        for (actual, expected) in zip(model.editing.position, moved) { XCTAssertEqual(actual, expected, accuracy: 0.00001) }
        model.lockPlacement()
        try await Task.sleep(for: .milliseconds(250))
        let lockedAfterMove = model.editing.position
        _ = try await dragBody(view, dx: 0.12, dy: 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.editing.position, lockedAfterMove, "Locked painting must reject body drags.")
        model.export()
        for _ in 0..<100 {
            if model.saved || model.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.saved)
        let saved = try JSONDecoder().decode(CharacterAsset.self, from: Data(contentsOf: asset.directory.appendingPathComponent("character.json")))
        XCTAssertEqual(saved.editing?.position, lockedAfterMove, "Dragged placement must persist when saving.")
    }

    @MainActor func testHumanStaysOnSurfacesAndRepairsIntersectingSavedPlacement() async throws {
        guard let existing = CharacterAsset.all().first(where: { $0.hasModel && $0.rigged }) else {
            throw XCTSkip("This collision test uses the cached human without spending credits.")
        }
        var legacyPlacement = CharacterEditingSettings()
        legacyPlacement.preset = "stand"
        legacyPlacement.position = [-2.25, 0.1, 1.6]
        legacyPlacement.room = true
        let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: existing.server, rigged: true, editing: legacyPlacement)
        try asset.save()
        try FileManager.default.copyItem(at: existing.directory.appendingPathComponent("source.glb"), to: asset.directory.appendingPathComponent("source.glb"))
        defer { try? FileManager.default.removeItem(at: asset.directory) }
        let model = Character3DModel(asset: asset)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CharacterWebView(model: model).frame(width: 420, height: 520))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitForViewer(model)
        let view = try XCTUnwrap(model.webView)
        func diagnostics() async throws -> [String: Any] {
            let value = try await view.callAsyncJavaScript("return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            return try XCTUnwrap(value)
        }
        try await Task.sleep(for: .milliseconds(400))
        var result = ["repaired": try await diagnostics()]
        model.command("detach")
        try await Task.sleep(for: .milliseconds(200))
        result["floor"] = try await diagnostics()
        XCTAssertEqual((result["floor"]?["surface"] as? [String: Any])?["surface"] as? String, "floor")
        _ = try await dragBody(view, dx: 0, dy: 0.12)
        try await Task.sleep(for: .milliseconds(100))
        result["afterHeight"] = try await diagnostics()
        model.editing.position = [0, 0, 0]
        try await Task.sleep(for: .milliseconds(200))
        model.preparePainting(againstWall: true)
        try await Task.sleep(for: .milliseconds(250))
        result["wall"] = try await diagnostics()
        _ = try await dragBody(view, dx: 0, dy: 0.12)
        try await Task.sleep(for: .milliseconds(100))
        result["wallRaised"] = try await diagnostics()
        func report(_ key: String) throws -> [String: Any] { try XCTUnwrap(result[key]) }
        for key in ["repaired", "floor", "afterHeight", "wall", "wallRaised"] {
            let state = try report(key)
            XCTAssertTrue(state["collision"] is NSNull, key)
            XCTAssertEqual(state["placementValid"] as? Bool, true, key)
            XCTAssertNotNil((state["surface"] as? [String: Any])?["surface"] as? String, key)
            XCTAssertEqual(try XCTUnwrap((state["surface"] as? [String: Any])?["gap"] as? Double), 0.006, accuracy: 0.00001, key)
        }
        let repairedPosition = try XCTUnwrap(try report("repaired")["placementPosition"] as? [Double])
        XCTAssertNotEqual(repairedPosition, [-2.25, 0.1, 1.6], "Old placements embedded inside the sofa must be repaired.")
        let floorPosition = try XCTUnwrap(try report("floor")["placementPosition"] as? [Double])
        let afterHeight = try XCTUnwrap(try report("afterHeight")["placementPosition"] as? [Double])
        XCTAssertEqual(floorPosition[1], afterHeight[1], accuracy: 0.00001, "Dragging up cannot lift a grounded person into empty space.")
        let wallPosition = try XCTUnwrap(try report("wall")["placementPosition"] as? [Double])
        let raisedPosition = try XCTUnwrap(try report("wallRaised")["placementPosition"] as? [Double])
        XCTAssertGreaterThan(raisedPosition[1], wallPosition[1], "Dragging up should slide the body along a real wall.")
        XCTAssertEqual(raisedPosition[2], wallPosition[2], accuracy: 0.00001)
        for preset in ["star", "prone", "crouch", "handsUp", "stand"] {
            model.editing.scale = 1.5
            model.selectPose(preset)
            try await Task.sleep(for: .milliseconds(350))
            let state = try await diagnostics()
            XCTAssertTrue(state["collision"] is NSNull, "Changing pose or size must not push any part through a surface.")
            XCTAssertEqual(state["placementValid"] as? Bool, true)
            result[preset] = state
        }
        model.editing.scale = 0.4
        model.selectPose("stand")
        try await Task.sleep(for: .milliseconds(350))
        let evidence = HouseStore.documents.appendingPathComponent("Verification/character-gameplay", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let screenshot = try await view.callAsyncJavaScript("window.characterViewer.action('inspect'); return window.characterViewer.screenshot()", arguments: [:], in: nil, contentWorld: .page) as? String
        try XCTUnwrap(screenshot.flatMap { Data(base64Encoded: $0) }).write(to: evidence.appendingPathComponent("surface-constrained-human.png"))
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("surface-constraints.json"))
        model.editing.position = [0, 0, 0]
        try await Task.sleep(for: .milliseconds(350))
        _ = try await view.callAsyncJavaScript("window.characterViewer.setRoom({surfaces: [{id:'small-floor', kind:'floor', dimensions:[0.5,0.1,0.5], position:[0,-0.05,0]}]})", arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(200))
        let before = try await diagnostics()
        XCTAssertEqual(before["placementValid"] as? Bool, true)
        model.selectPose("tpose")
        try await Task.sleep(for: .milliseconds(400))
        let blockedAnimation = try await diagnostics()
        XCTAssertEqual(blockedAnimation["preset"] as? String, "stand", "An interrupted pose must restore a complete safe pose, not leave a partial animation labeled as the new pose.")
        let safeJoints = try XCTUnwrap(before["joints"] as? [[String: Any]])
        let restoredJoints = try XCTUnwrap(blockedAnimation["joints"] as? [[String: Any]])
        for (safe, restored) in zip(safeJoints, restoredJoints) {
            for (coordinate, actual) in zip(try XCTUnwrap(safe["position"] as? [Double]), try XCTUnwrap(restored["position"] as? [Double])) {
                XCTAssertEqual(coordinate, actual, accuracy: 0.00001)
            }
        }
        model.editing.scale = 1.5
        model.selectPose("star")
        try await Task.sleep(for: .milliseconds(400))
        let rejected = try await diagnostics()
        XCTAssertEqual(rejected["placementValid"] as? Bool, true)
        XCTAssertEqual(rejected["preset"] as? String, "stand", "An impossible size/pose must restore the last safe body, not overlap the room.")
        XCTAssertTrue(rejected["collision"] is NSNull)
    }

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

    /// Drags the body from its projected center by a normalized-device offset, using real canvas pointer events.
    @MainActor private func dragBody(_ view: WKWebView, dx: Double, dy: Double) async throws -> [String: [String: Any]] {
        let value = try await view.callAsyncJavaScript("""
            const viewer = window.characterViewer, canvas = document.querySelector('canvas'), rect = canvas.getBoundingClientRect();
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            const before = viewer.diagnostics(), [x, y] = before.manipulation.center;
            const fire = (type, step) => canvas.dispatchEvent(new PointerEvent(type, {bubbles: true, cancelable: true, pointerId: 95, pointerType: 'touch',
              button: type === 'pointermove' ? -1 : 0, clientX: rect.left + (x + dx * step / 5 + 1) / 2 * rect.width, clientY: rect.top + (1 - y - dy * step / 5) / 2 * rect.height}));
            fire('pointerdown', 0);
            for (let step = 1; step <= 5; step++) fire('pointermove', step);
            fire('pointerup', 5);
            return { before, after: viewer.diagnostics() };
            """, arguments: ["dx": dx, "dy": dy], in: nil, contentWorld: .page) as? [String: [String: Any]]
        return try XCTUnwrap(value)
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
