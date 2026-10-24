import XCTest
import SwiftUI
@testable import Rally

final class CharacterGameTests: XCTestCase {
    @MainActor func testTwoNativeEditorsPublishRenderAndTagThroughNextJS() async throws {
        let address = try XCTUnwrap(URL(string: "http://localhost:3099"))
        var health = URLRequest(url: address.appendingPathComponent("health"))
        health.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: health),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Run the isolated Next.js integration server on localhost:3099 for the native multiplayer test.")
        }
        guard let existing = CharacterAsset.all().first(where: { $0.hasModel && $0.rigged }) else {
            throw XCTSkip("Generate a human once; this test never spends API credits.")
        }
        let api = LobbyAPI(baseURL: address)
        let host: JoinResponse = try await api.request("rooms", method: "POST", body: ["name": "Native host", "avatar": 0])
        let roomPath = "rooms/\(host.room.code)"
        defer { Task { _ = try? await api.request(roomPath + "/leave", method: "POST", token: host.token, body: [:]) as EmptyResponse } }
        let guest: JoinResponse = try await api.request(roomPath + "/join", method: "POST", body: ["name": "Native hider", "avatar": 1])
        _ = try await api.request(roomPath + "/me", method: "PATCH", token: guest.token, body: ["ready": true]) as RoomResponse
        func makeEditor() throws -> Character3DModel {
            let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: existing.server, rigged: true)
            try asset.save()
            try FileManager.default.copyItem(at: existing.directory.appendingPathComponent("source.glb"), to: asset.directory.appendingPathComponent("source.glb"))
            return Character3DModel(asset: asset)
        }
        let hunter = try makeEditor(), hider = try makeEditor()
        defer {
            for editor in [hunter, hider] {
                if let directory = editor.asset?.directory { try? FileManager.default.removeItem(at: directory) }
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VStack {
            CharacterWebView(model: hunter).frame(height: 350)
            CharacterWebView(model: hider).frame(height: 350)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<300 {
            if hunter.viewerLoaded && hider.viewerLoaded { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(hunter.viewerLoaded && hider.viewerLoaded)
        let huntingGame = CharacterGameModel(), hidingGame = CharacterGameModel()
        huntingGame.connect(GameConnection(server: address, code: host.room.code, memberID: host.memberID, token: host.token, isHost: true), editor: hunter)
        hidingGame.connect(GameConnection(server: address, code: host.room.code, memberID: guest.memberID, token: guest.token, isHost: false), editor: hider)
        defer { huntingGame.stop(); hidingGame.stop() }
        hider.selectPose("stand")
        hider.editing.color = "#28a4bf"
        try await Task.sleep(for: .milliseconds(400))
        hider.command("fill")
        hider.command("clone")
        hider.lockPlacement()
        hidingGame.publishCurrent()
        for _ in 0..<300 {
            if !hidingGame.busy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(hidingGame.error)
        XCTAssertEqual(hidingGame.snapshot?.published, [guest.memberID])
        huntingGame.start(mode: "basic", preparation: 5, hunt: 60, autoTaunt: false)
        let view = try XCTUnwrap(hunter.webView)
        for _ in 0..<40 {
            if huntingGame.snapshot?.isWaitingToHunt == true && !view.isUserInteractionEnabled { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(huntingGame.snapshot?.isWaitingToHunt, true)
        XCTAssertFalse(view.isUserInteractionEnabled, "The hunter cannot interact with the scene while hiders prepare.")
        XCTAssertEqual(huntingGame.snapshot?.visible.count, 0)
        XCTAssertEqual(hider.webView?.isUserInteractionEnabled, true)
        var rendered = false
        for _ in 0..<200 {
            if huntingGame.snapshot?.phase == "hunting" {
                let result = try await view.callAsyncJavaScript("return window.characterViewer.diagnostics().remoteOwners", arguments: [:], in: nil, contentWorld: .page) as? [String]
                if result?.contains(guest.memberID) == true { rendered = true; break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(rendered, huntingGame.error ?? "The real published human must load in the hunter's renderer.")
        XCTAssertTrue(view.isUserInteractionEnabled, "Hunter controls return when the hunt begins.")
        let original = try await hider.webView?.callAsyncJavaScript("return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        for _ in 0..<50 {
            if hidingGame.snapshot?.eject?.available == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(hidingGame.snapshot?.eject?.available, true)
        hidingGame.eject()
        for _ in 0..<200 {
            if !hidingGame.busy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(hidingGame.error)
        XCTAssertEqual(hidingGame.snapshot?.eject?.used, true)
        let moved = try await hider.webView?.callAsyncJavaScript("return window.characterViewer.diagnostics()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let before = try XCTUnwrap(original?["bounds"] as? [String: [Double]])
        let after = try XCTUnwrap(moved?["bounds"] as? [String: [Double]])
        XCTAssertNotEqual(before["min"], after["min"])
        XCTAssertEqual(original?["paint"] as? NSNumber, moved?["paint"] as? NSNumber)
        XCTAssertEqual(original?["preset"] as? String, moved?["preset"] as? String)
        let destination = try XCTUnwrap(hidingGame.snapshot?.eject?.bounds)
        for (actual, expected) in zip(try XCTUnwrap(after["min"]), destination.min) { XCTAssertEqual(actual, expected, accuracy: 0.0001) }
        var updatedRemote = false
        for _ in 0..<100 {
            let reports = try await view.callAsyncJavaScript("return window.characterViewer.diagnostics().remoteBounds", arguments: [:], in: nil, contentWorld: .page) as? [String: [String: [Double]]]
            if let minimum = reports?[guest.memberID]?["min"], zip(minimum, destination.min).allSatisfy({ abs($0 - $1) < 0.0001 }) { updatedRemote = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(updatedRemote, "The seeker must render the same ejected location as the hider and server.")
        let center = zip(destination.min, destination.max).map { ($0 + $1) / 2 }
        _ = try await view.callAsyncJavaScript("window.characterViewer.lookAt(point)", arguments: ["point": center], in: nil, contentWorld: .page)
        let evidence = HouseStore.documents.appendingPathComponent("Verification/character-gameplay", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let screenshot = try await view.callAsyncJavaScript("return window.characterViewer.screenshot()", arguments: [:], in: nil, contentWorld: .page) as? String
        try XCTUnwrap(screenshot.flatMap { Data(base64Encoded: $0) }).write(to: evidence.appendingPathComponent("multiplayer-hunt.png"))
        let aim = try await view.callAsyncJavaScript("for (let vertical = -0.9; vertical <= 0.9; vertical += 0.1) for (let horizontal = -0.9; horizontal <= 0.9; horizontal += 0.1) { const ray = window.characterViewer.aimAt(horizontal, vertical); if (ray.targetID === target) return ray; } return null;", arguments: ["target": guest.memberID], in: nil, contentWorld: .page) as? [String: Any]
        hunter.onShot?(try XCTUnwrap(aim, "The aiming ray must intersect actual rendered human triangles."))
        for _ in 0..<100 {
            if huntingGame.snapshot?.phase == "finished" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(huntingGame.error)
        XCTAssertEqual(huntingGame.snapshot?.winner, "hunters")
        XCTAssertEqual(huntingGame.snapshot?.scores.first(where: { $0.id == host.memberID })?.points, 500)
        XCTAssertEqual(huntingGame.snapshot?.scores.first(where: { $0.id == guest.memberID })?.found, true)
    }
}
