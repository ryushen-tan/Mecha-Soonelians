import Foundation

struct RigBone: Identifiable {
    let id: String
    let label: String
    let start: String
    let end: String
    let parent: String?

    static let all: [RigBone] = [
        .init(id: "spine", label: "Torso", start: "root", end: "neck", parent: nil),
        .init(id: "head", label: "Head", start: "neck", end: "nose", parent: "spine"),
        .init(id: "leftUpperArm", label: "Left upper arm", start: "leftShoulder", end: "leftElbow", parent: "spine"),
        .init(id: "leftForearm", label: "Left forearm", start: "leftElbow", end: "leftWrist", parent: "leftUpperArm"),
        .init(id: "rightUpperArm", label: "Right upper arm", start: "rightShoulder", end: "rightElbow", parent: "spine"),
        .init(id: "rightForearm", label: "Right forearm", start: "rightElbow", end: "rightWrist", parent: "rightUpperArm"),
        .init(id: "leftThigh", label: "Left thigh", start: "leftHip", end: "leftKnee", parent: nil),
        .init(id: "leftShin", label: "Left shin", start: "leftKnee", end: "leftAnkle", parent: "leftThigh"),
        .init(id: "rightThigh", label: "Right thigh", start: "rightHip", end: "rightKnee", parent: nil),
        .init(id: "rightShin", label: "Right shin", start: "rightKnee", end: "rightAnkle", parent: "rightThigh")
    ]
}

struct BodyRig {
    let joints: [BodyJoint]
    let imageSize: CGSize

    var points: [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: joints.map { ($0.name, CGPoint(x: $0.point.x * imageSize.width, y: $0.point.y * imageSize.height)) })
    }

    var bones: [RigBone] {
        let available = points
        return RigBone.all.filter { available[$0.start] != nil && available[$0.end] != nil }
    }

    func transforms(angles: [String: Double]) -> [String: CGAffineTransform] {
        let rest = points
        var result: [String: CGAffineTransform] = [:]
        for bone in bones {
            guard let pivot = rest[bone.start] else { continue }
            let parent = bone.parent.flatMap { result[$0] } ?? .identity
            let angle = (angles[bone.id] ?? 0) * .pi / 180
            let rotation = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
            result[bone.id] = rotation.concatenating(parent)
        }
        return result
    }

    func posedPoints(angles: [String: Double]) -> [String: CGPoint] {
        let rest = points
        let matrices = transforms(angles: angles)
        var posed = rest
        for bone in bones {
            guard let transform = matrices[bone.id] else { continue }
            posed[bone.start] = rest[bone.start]?.applying(transform)
            posed[bone.end] = rest[bone.end]?.applying(transform)
        }
        return posed
    }

    func distanceToSegment(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let lengthSquared = delta.x * delta.x + delta.y * delta.y
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let fraction = min(1, max(0, ((point.x - start.x) * delta.x + (point.y - start.y) * delta.y) / lengthSquared))
        return hypot(point.x - start.x - fraction * delta.x, point.y - start.y - fraction * delta.y)
    }
}
