import XCTest
import UIKit
import RealityKit
@testable import MechaSoonelians

final class PersonalBodyTests: XCTestCase {
    func testShotsStopAtFurnitureAndWallsButPassThroughDoorways() throws {
        let triangle = BodySurface(.init(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                         uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)], triangles: [SIMD3(0, 1, 2)]), textureSize: 32)
        XCTAssertNotNil(triangle.hit(origin: SIMD3(0.2, 0.2, 2), direction: SIMD3(0, 0, -1)))
        XCTAssertNil(triangle.hit(origin: SIMD3(0.9, 0.9, 2), direction: SIMD3(0, 0, -1)),
                     "Empty space inside a figure's bounding box is not a hit.")
        var transform = matrix_identity_float4x4
        transform.columns.3.z = -2
        let box = RoomObstacles.Box(transform: transform, halfSize: SIMD3(1, 1, 0.1))
        let room = RoomObstacles(walls: [.init(box: box, gaps: [-0.3...0.3])])
        XCTAssertNil(room.shotDistance(from: .zero, direction: SIMD3(0, 0, -1)))
        XCTAssertEqual(try XCTUnwrap(room.shotDistance(from: SIMD3(0.7, 0, 0), direction: SIMD3(0, 0, -1))), 1.9, accuracy: 0.001)
        XCTAssertNil(room.shotDistance(from: SIMD3(0.7, 0, 0), direction: SIMD3(0, 0, 1)))
        let furniture = RoomObstacles(furniture: [box])
        XCTAssertEqual(try XCTUnwrap(furniture.shotDistance(from: .zero, direction: SIMD3(0, 0, -1))), 1.9, accuracy: 0.001)
        XCTAssertNil(furniture.shotDistance(from: SIMD3(2, 0, 0), direction: SIMD3(0, 0, -1)))
        XCTAssertNil(furniture.shotDistance(from: .zero, direction: SIMD3(0, 0, -1), limit: 1))
    }

    @MainActor func testFoundFigureKeepsOriginalSkinVisibleAndRevealsOnlyOnce() throws {
        let source = try XCTUnwrap(ChameleonBody.shared)
        var archive = try JSONDecoder().decode(CharacterBodyArchive.self, from: source.exportedPose(0))
        func image(_ color: UIColor, size: Int = 8) throws -> Data {
            try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
            }()).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }.pngData())
        }
        archive.originalTexture = try image(.magenta)
        let restored = try XCTUnwrap(ChameleonBody(archive: archive))
        let transfer = try restored.exportedPose(0)
        let received = try XCTUnwrap(ChameleonBody(archive: JSONDecoder().decode(CharacterBodyArchive.self, from: transfer)))
        let original = PaintCanvas()
        original.restore(try XCTUnwrap(received.initialTexture))
        XCTAssertGreaterThan(original.pixels[0], 240)
        XCTAssertLessThan(original.pixels[1], 10)
        XCTAssertGreaterThan(original.pixels[2], 240)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reveal-\(UUID()).body")
        try transfer.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var ghost = Ghost(id: UUID(), ownerID: UUID(), transform: matrix_identity_float4x4.floats,
                          floorTransform: matrix_identity_float4x4.floats, flushBack: false, hasModel: true,
                          paintedBody: true, pose: source.poses[0].id, width: 0.5, height: 1.75, foundBy: nil)
        let ar = ARGameController()
        let paint = try image(.blue, size: 32)
        var behindTransform = matrix_identity_float4x4
        behindTransform.columns.3.z = -2
        let behind = Ghost(id: UUID(), ownerID: UUID(), transform: behindTransform.floats, floorTransform: behindTransform.floats,
                           flushBack: false, hasModel: true, paintedBody: true, pose: ghost.pose, width: 0.5, height: 1.75, foundBy: nil)
        let images = [ghost.id: paint, behind.id: paint], models = [ghost.id: file, behind.id: file]
        ar.show([ghost, behind], images: images, models: models)
        let entity = try XCTUnwrap(ar.arView.scene.findEntity(named: ghost.id.uuidString))
        let model = try XCTUnwrap(entity.children.first as? ModelEntity)
        let bounds = model.visualBounds(relativeTo: nil)
        let origin = bounds.center + SIMD3<Float>(0, 0, 3)
        let direction = SIMD3<Float>(0, 0, -1)
        XCTAssertEqual(ar.shotTarget(from: origin, direction: direction).id, ghost.id)
        XCTAssertNil(ar.shotTarget(from: origin + SIMD3(3, 0, 0), direction: direction).id)
        XCTAssertNil(ar.shotTarget(from: origin, direction: direction, limit: 1).id, "A nearer real surface must block the hit.")
        func texture() throws -> TextureResource {
            let material = try XCTUnwrap(model.model?.materials.first as? UnlitMaterial)
            return try XCTUnwrap(material.color.texture?.resource)
        }
        let camouflage = try texture()
        ghost.foundBy = UUID()
        ar.show([ghost, behind], images: images, models: models)
        let skin = try texture()
        XCTAssertEqual(camouflage.width, 32)
        XCTAssertEqual(skin.width, 8, "The original texture replaces the spray texture.")
        XCTAssertTrue(entity.isEnabled)
        XCTAssertNil(ar.shotTarget(from: origin, direction: direction).id, "A found figure cannot be scored again or shot through to find someone behind it.")
        XCTAssertNotNil(entity.findEntity(named: "found-marker"))
        ar.show([ghost, behind], images: images, models: models)
        XCTAssertEqual(try texture().width, skin.width)
        XCTAssertEqual(entity.children.filter { $0.name == "found-marker" }.count, 1)
    }

    func testFastSprayRetainsPositionColorAndSoftFalloff() throws {
        for uv in [SIMD2<Float>(0.25, 0.7), SIMD2(0.998, 0.001), SIMD2(0.003, 0.99)] {
            let canvas = PaintCanvas()
            let size = PaintCanvas.size
            let radius: Float = 28
            let color = SIMD3<Float>(40, 80, 130)
            let cx = uv.x * Float(size), cy = (1 - uv.y) * Float(size)
            canvas.splat(at: uv, radius: radius, color: color, strength: 0.3)
            var maximumDifference = 0
            for y in max(0, Int(cy - radius) - 1)...min(size - 1, Int(cy + radius) + 1) {
                for x in max(0, Int(cx - radius) - 1)...min(size - 1, Int(cx + radius) + 1) {
                    let dx = Float(x) + 0.5 - cx, dy = Float(y) + 0.5 - cy
                    let amount = 0.3 * max(0, 1 - (dx * dx + dy * dy) / (radius * radius))
                    for channel in 0..<3 {
                        let old: Float = channel == 2 ? 241 : 244
                        let expected = Int((old + (color[channel] - old) * amount).rounded())
                        maximumDifference = max(maximumDifference, abs(expected - Int(canvas.pixels[(y * size + x) * 4 + channel])))
                    }
                }
            }
            XCTAssertLessThanOrEqual(maximumDifference, 3, "The fast brush must match the previous brush within rounding/interpolation tolerance.")
            XCTAssertEqual(canvas.pixels[(size / 2 * size + size / 2) * 4], 244, "Pixels outside the brush stay unchanged.")
        }
    }

    func testIncrementalSeamsUndoAndImageSnapshotsStayConsistent() throws {
        let canvas = PaintCanvas()
        let size = PaintCanvas.size
        let first = 300 * size + 250, second = 700 * size + 750
        canvas.gutter = [SIMD2(Int32(first - 70), Int32(first)), SIMD2(Int32(second + 70), Int32(second))]
        let original = try XCTUnwrap(canvas.image())
        let originalBytes = canvas.pixels
        XCTAssertTrue(original === canvas.image(), "Unchanged images should be reused.")
        canvas.beginStroke()
        canvas.splat(at: SIMD2(250.5 / Float(size), 1 - 300.5 / Float(size)), radius: 8, color: SIMD3(0, 0, 0), strength: 1)
        let firstImage = try XCTUnwrap(canvas.image())
        XCTAssertEqual(canvas.pixels[(first - 70) * 4], canvas.pixels[first * 4])
        XCTAssertLessThan(canvas.pixels[first * 4], 5)
        let firstBytes = canvas.pixels
        canvas.beginStroke()
        canvas.splat(at: SIMD2(750.5 / Float(size), 1 - 700.5 / Float(size)), radius: 8, color: SIMD3(0, 0, 0), strength: 1)
        _ = canvas.image()
        XCTAssertEqual(canvas.pixels[(second + 70) * 4], canvas.pixels[second * 4])
        XCTAssertEqual(canvas.pixels[(first - 70) * 4], firstBytes[(first - 70) * 4])
        canvas.undo()
        _ = canvas.image()
        XCTAssertEqual(canvas.pixels, firstBytes)
        canvas.undo()
        _ = canvas.image()
        XCTAssertEqual(canvas.pixels, originalBytes)
        XCTAssertFalse(canvas.canUndo)
        // Painting only a padding texel must still recopy its untouched surface texel.
        canvas.splat(at: SIMD2(180.5 / Float(size), 1 - 300.5 / Float(size)), radius: 2, color: SIMD3(0, 0, 0), strength: 1)
        XCTAssertLessThan(canvas.pixels[(first - 70) * 4], 10)
        _ = canvas.image()
        XCTAssertEqual(canvas.pixels[(first - 70) * 4], canvas.pixels[first * 4])
        XCTAssertEqual((firstImage.dataProvider?.data as Data?), Data(firstBytes),
                       "Previously published texture images must not change with later strokes or undo.")
        XCTAssertNotNil(canvas.jpeg())
    }

    @MainActor func testSprayWorkloadTiming() async throws {
        let body = try XCTUnwrap(ChameleonBody.shared)
        let mesh = body.mesh(0)
        let surface = BodySurface(mesh, textureSize: PaintCanvas.size)
        let canvas = PaintCanvas()
        canvas.gutter = BodySurface.gutter(of: mesh, size: PaintCanvas.size)
        let image = try XCTUnwrap(canvas.image())
        let texture = try await TextureResource(image: image, options: .init(semantic: .color))
        let iterations = 12
        var rayTime = 0.0, paintTime = 0.0, imageTime = 0.0, uploadTime = 0.0
        canvas.beginStroke()
        for batch in 0..<iterations {
            var start = CACurrentMediaTime()
            for drop in 0..<48 {
                _ = surface.hit(origin: SIMD3(Float(drop % 8) * 0.015, 0.9, 2), direction: SIMD3(0, 0, -1))
            }
            rayTime += CACurrentMediaTime() - start
            start = CACurrentMediaTime()
            for drop in 0..<48 {
                canvas.splat(at: SIMD2(0.3 + Float(drop % 8) * 0.01, 0.4 + Float(batch) * 0.01),
                             radius: 28, color: SIMD3(40, 80, 130), strength: 0.3)
            }
            paintTime += CACurrentMediaTime() - start
            start = CACurrentMediaTime()
            let updated = try XCTUnwrap(canvas.image())
            imageTime += CACurrentMediaTime() - start
            start = CACurrentMediaTime()
            try texture.replace(withImage: updated, options: .init(semantic: .color))
            uploadTime += CACurrentMediaTime() - start
        }
        print("SPRAY_BENCH rays_ms=\(rayTime * 1000 / Double(iterations)) paint_ms=\(paintTime * 1000 / Double(iterations)) image_ms=\(imageTime * 1000 / Double(iterations)) upload_ms=\(uploadTime * 1000 / Double(iterations))")
        XCTAssertTrue(canvas.canUndo)
    }

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
