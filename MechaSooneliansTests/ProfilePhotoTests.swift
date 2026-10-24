import XCTest
import SceneKit
@testable import MechaSoonelians

final class ProfilePhotoTests: XCTestCase {
    func testFullNameMatchingIgnoresCaseAndWhitespace() {
        XCTAssertEqual(ProfilePhotos.filename(for: "Kai Song"), "kai-song.jpg")
        XCTAssertEqual(ProfilePhotos.filename(for: "  kAI   SONG  "), "kai-song.jpg")
        XCTAssertEqual(ProfilePhotos.filename(for: "Ved Thakar"), "ved-thakar-00202b247.jpg")
    }

    func testPartialUnknownAndMissingPhotoNamesUseFallback() {
        for name in ["", "Kai", "Song", "Kai Song Jr", "Unknown Person", "Jaden Hum"] {
            XCTAssertNil(ProfilePhotos.filename(for: name), name)
            XCTAssertNil(ProfilePhotos.image(for: name), name)
        }
    }

    func testEveryImportedPhotoLoadsFromAppBundle() {
        XCTAssertEqual(ProfilePhotos.entries.count, 42)
        for entry in ProfilePhotos.entries {
            XCTAssertNotNil(ProfilePhotos.image(for: entry.name), entry.name)
            XCTAssertNotNil(ProfilePhotos.avatarImage(for: entry.name), entry.name)
            XCTAssertNotNil(ProfilePhotos.faceTexture(for: entry.name), entry.name)
        }
    }

    func testEveryAIAvatarIncludesThreeDistinctPortraitViews() throws {
        for entry in ProfilePhotos.entries {
            let views = try ProfilePhotos.AvatarView.allCases.map { view in
                try XCTUnwrap(ProfilePhotos.avatarImage(for: entry.name, view: view), "\(entry.name): \(view.title)")
            }
            for image in views {
                XCTAssertEqual(image.size.height, 887, entry.name)
                XCTAssertTrue((591...592).contains(Int(image.size.width)), entry.name)
            }
            XCTAssertNotEqual(views[0].pngData(), views[1].pngData(), entry.name)
            XCTAssertNotEqual(views[0].pngData(), views[2].pngData(), entry.name)
        }
        for view in ProfilePhotos.AvatarView.allCases {
            XCTAssertNil(ProfilePhotos.avatarImage(for: "Jaden Hum", view: view))
            XCTAssertNil(ProfilePhotos.avatarImage(for: "Unknown Person", view: view))
        }
    }

    func testAvatarUsesCurvedTexturedMeshOnBlankBody() throws {
        let texture = try XCTUnwrap(ProfilePhotos.faceTexture(for: "Kai Song")?.cgImage)
        let scene = ProfileAvatarMesh.scene(texture: texture)
        for part in ["head", "neck", "shoulders", "avatar-camera"] {
            XCTAssertNotNil(scene.rootNode.childNode(withName: part, recursively: false))
        }
        XCTAssertNil(scene.rootNode.childNode(withName: "profile-face-mesh", recursively: false), "No separate face patch")
        let face = try XCTUnwrap(scene.rootNode.childNode(withName: "head", recursively: false)?.geometry)
        XCTAssertGreaterThan(try XCTUnwrap(face.sources(for: .vertex).first).vectorCount, 1000)
        XCTAssertEqual(face.sources(for: .texcoord).first?.vectorCount, face.sources(for: .vertex).first?.vectorCount)
        XCTAssertNotNil(face.firstMaterial?.diffuse.contents)
        XCTAssertLessThan(face.boundingBox.min.z, -0.5, "Texture must cover the back of the head")
        XCTAssertGreaterThan(face.boundingBox.max.z, 0.5)
        XCTAssertGreaterThan(face.boundingBox.max.y - face.boundingBox.min.y, 1.6, "Head must include both poles")
        XCTAssertEqual(texture.width, texture.height * 2, "Full head uses a 360-degree texture atlas")
        XCTAssertNil(ProfilePhotos.avatarImage(for: "Unknown Person"))
        XCTAssertNil(ProfilePhotos.faceTexture(for: "Jaden Hum"))
    }

    func testRoomResponseNamesResolveForAllMembers() throws {
        let data = Data(#"{"room":{"code":"482916","locked":false,"status":"waiting","createdAt":"2026-10-24","members":[{"id":"1","name":"Kai Song","avatar":0,"host":true,"ready":true},{"id":"2","name":"Justin Fan","avatar":1,"host":false,"ready":true}]}}"#.utf8)
        let response = try JSONDecoder().decode(RoomResponse.self, from: data)
        XCTAssertEqual(response.room.members.compactMap { ProfilePhotos.filename(for: $0.name) },
                       ["kai-song.jpg", "justinfan951.jpg"])
    }

    func testHeadTexturesAreOpaqueAndMeetAtTheRearSeam() throws {
        for entry in ProfilePhotos.entries {
            let texture = try XCTUnwrap(ProfilePhotos.faceTexture(for: entry.name)?.cgImage)
            let width = texture.width, height = texture.height
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(texture, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = try XCTUnwrap(bitmap.data?.assumingMemoryBound(to: UInt8.self))
            for row in 0..<height {
                for column in stride(from: 0, to: width, by: 16) {
                    XCTAssertEqual(pixels[(row * width + column) * 4 + 3], 255, entry.name)
                }
                for channel in 0..<3 {
                    let left = Int(pixels[row * width * 4 + channel])
                    let right = Int(pixels[(row * width + width - 1) * 4 + channel])
                    XCTAssertLessThanOrEqual(abs(left - right), 1, "Rear seam: \(entry.name)")
                }
            }
        }
    }
}
