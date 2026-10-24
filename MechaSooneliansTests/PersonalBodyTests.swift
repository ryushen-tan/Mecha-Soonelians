import XCTest
import UIKit
@testable import MechaSoonelians

final class PersonalBodyTests: XCTestCase {
    func testPosedBodySurvivesPeerTransferWithoutUsingRecipientsBody() throws {
        let source = try XCTUnwrap(ChameleonBody.shared)
        let index = try XCTUnwrap(source.index(of: "crouch"))
        let data = try source.exportedPose(index)
        let archive = try JSONDecoder().decode(CharacterBodyArchive.self, from: data)
        XCTAssertTrue(archive.isValid)
        XCTAssertEqual(archive.info.poses.map(\.id), ["crouch"])
        let received = try XCTUnwrap(ChameleonBody(archive: archive))
        XCTAssertEqual(received.mesh(0).positions, source.mesh(index).positions)
        XCTAssertEqual(received.mesh(0).uvs, source.mesh(index).uvs)
        XCTAssertEqual(received.mesh(0).triangles, source.mesh(index).triangles)
        XCTAssertEqual(received.bounds[0].min, source.bounds[index].min)
        XCTAssertEqual(received.bounds[0].max, source.bounds[index].max)
        XCTAssertNil(received.index(of: "stand"))
    }

    func testSavedPersonalBodyKeepsItsOwnTextureAndPoseWheel() throws {
        let source = try XCTUnwrap(ChameleonBody.shared)
        let infoURL = try XCTUnwrap(Bundle.main.url(forResource: "chameleon-poses", withExtension: "json", subdirectory: "CharacterViewer"))
        let dataURL = try XCTUnwrap(Bundle.main.url(forResource: "chameleon-poses", withExtension: "bin", subdirectory: "CharacterViewer"))
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "chameleon-base", withExtension: "glb", subdirectory: "CharacterViewer"))
        let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: "https://no-network.invalid", rigged: true)
        let previous = UserDefaults.standard.string(forKey: CharacterProfile.preferenceKey)
        try asset.save()
        defer {
            UserDefaults.standard.set(previous, forKey: CharacterProfile.preferenceKey)
            try? FileManager.default.removeItem(at: asset.directory)
        }
        try FileManager.default.copyItem(at: modelURL, to: asset.directory.appendingPathComponent("source.glb"))
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.pngData())
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: infoURL))
        try CharacterProfile.saveBody(["info": info, "data": try Data(contentsOf: dataURL).base64EncodedString(), "texture": png.base64EncodedString()], for: asset)
        let body = try XCTUnwrap(ChameleonBody.personal)
        XCTAssertNotNil(body.initialTexture)
        XCTAssertEqual(body.poses.map(\.id), source.poses.map(\.id))
        XCTAssertEqual(body.mesh(0).positions, source.mesh(0).positions)
        let canvas = PaintCanvas()
        canvas.restore(try XCTUnwrap(body.initialTexture))
        XCTAssertGreaterThan(canvas.pixels[0], 240)
        XCTAssertLessThan(canvas.pixels[1], 10)
        XCTAssertGreaterThan(canvas.pixels[2], 240)
        XCTAssertFalse(canvas.canUndo)
    }

    func testTextureSeedRetainsTopAndBottomOrientation() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 4, width: 8, height: 4))
        }
        let canvas = PaintCanvas()
        canvas.restore(try XCTUnwrap(image.cgImage))
        XCTAssertGreaterThan(canvas.pixels[0], 240)
        XCTAssertLessThan(canvas.pixels[2], 10)
        let lastRow = (PaintCanvas.size - 1) * PaintCanvas.size * 4
        XCTAssertLessThan(canvas.pixels[lastRow], 10)
        XCTAssertGreaterThan(canvas.pixels[lastRow + 2], 240)
    }
}
