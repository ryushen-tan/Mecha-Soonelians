import Foundation
import RealityKit
import simd

/// The white chameleon body in every pose, baked by Tools/ChameleonModel/bake-poses.mjs. Every pose
/// has the same vertices and texture layout, so paint stays put when the pose changes, and other
/// phones only need the pose's name and the paint.
final class ChameleonBody {
    struct Pose: Decodable {
        let id: String
        let name: String
        let icon: String
    }

    static let shared = ChameleonBody()

    let poses: [Pose]
    /// Each pose's box, in the body's own units (1.75 tall when standing).
    let bounds: [(min: SIMD3<Float>, max: SIMD3<Float>)]
    private let uvs: [SIMD2<Float>]
    private let triangles: [SIMD3<Int32>]
    private let positions: [[SIMD3<Float>]]

    private struct Info: Decodable {
        let vertexCount: Int
        let triangleCount: Int
        let poses: [Pose]
    }

    private init?() {
        guard let infoURL = Bundle.main.url(forResource: "chameleon-poses", withExtension: "json", subdirectory: "CharacterViewer"),
              let dataURL = Bundle.main.url(forResource: "chameleon-poses", withExtension: "bin", subdirectory: "CharacterViewer"),
              let info = try? JSONDecoder().decode(Info.self, from: Data(contentsOf: infoURL)),
              let data = try? Data(contentsOf: dataURL) else { return nil }
        let vertices: Int = info.vertexCount, triangleCount: Int = info.triangleCount
        let expectedSize: Int = vertices * 8 + triangleCount * 12 + info.poses.count * vertices * 12
        guard !info.poses.isEmpty, data.count == expectedSize else { return nil }
        let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let integers: [UInt32] = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        uvs = (0..<vertices).map { (i: Int) -> SIMD2<Float> in SIMD2(floats[i * 2], floats[i * 2 + 1]) }
        let indexStart: Int = vertices * 2
        let indices = integers[indexStart..<(indexStart + triangleCount * 3)].map { Int32(bitPattern: $0) }
        guard indices.allSatisfy({ $0 >= 0 && Int($0) < vertices }) else { return nil }
        triangles = (0..<triangleCount).map { (t: Int) -> SIMD3<Int32> in SIMD3(indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]) }
        let positionStart: Int = indexStart + triangleCount * 3
        positions = (0..<info.poses.count).map { (pose: Int) -> [SIMD3<Float>] in
            let start: Int = positionStart + pose * vertices * 3
            return (0..<vertices).map { (i: Int) -> SIMD3<Float> in SIMD3(floats[start + i * 3], floats[start + i * 3 + 1], floats[start + i * 3 + 2]) }
        }
        poses = info.poses
        bounds = positions.map { (points: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>) in
            points.reduce((min: points[0], max: points[0])) { (box: (min: SIMD3<Float>, max: SIMD3<Float>), point: SIMD3<Float>) in
                (min: simd_min(box.min, point), max: simd_max(box.max, point))
            }
        }
    }

    func index(of id: String?) -> Int? { poses.firstIndex { $0.id == id } }

    /// The pose's surface, in the body's own units (1.75 tall when standing).
    func mesh(_ pose: Int) -> BodySurface.Mesh {
        BodySurface.Mesh(positions: positions[pose], uvs: uvs, triangles: triangles)
    }

    /// The posed body wearing `paint` exactly as painted, seen from both sides (its faces don't all point the same way).
    func entity(_ pose: Int, paint: TextureResource) throws -> ModelEntity {
        var descriptor = MeshDescriptor(name: "chameleon")
        descriptor.positions = MeshBuffers.Positions(positions[pose])
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(triangles.flatMap { [UInt32($0.x), UInt32($0.y), UInt32($0.z), UInt32($0.x), UInt32($0.z), UInt32($0.y)] })
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(paint))
        return ModelEntity(mesh: try MeshResource.generate(from: [descriptor]), materials: [material])
    }
}
