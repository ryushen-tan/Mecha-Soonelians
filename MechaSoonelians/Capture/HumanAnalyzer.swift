import CoreImage
import Foundation
import Vision

struct BodyJoint: Codable {
    let name: String
    var point: CGPoint
    let confidence: Float
}

struct HumanDetection: Identifiable {
    let id: Int
    let bounds: CGRect
    let joints: [BodyJoint]
    let cutout: CGImage
    let mask: CGImage

    var generationWarning: String? {
        let visible = Set(joints.filter { $0.confidence >= 0.2 }.map(\.name))
        if !visible.isSuperset(of: ["leftAnkle", "rightAnkle", "leftWrist", "rightWrist"]) || bounds.maxY > 0.995 {
            return "The scan could not verify both hands and feet inside the frame. Retake a full-body photo before using credits; cropped limbs can remain missing in the 3D mesh."
        }
        for side in ["left", "right"] {
            if let hip = joints.first(where: { $0.name == side + "Hip" }), let knee = joints.first(where: { $0.name == side + "Knee" }),
               abs(knee.point.y - hip.point.y) < abs(knee.point.x - hip.point.x) * 0.8 {
                return "This looks like a seated or foreshortened capture. Standing with arms separated from the torso reduces fused surfaces and stretched poses."
            }
        }
        return nil
    }
}

struct HumanSampleMetadata: Codable {
    let id: Int
    let bounds: CGRect
    let joints: [BodyJoint]
}

enum HumanAnalyzer {
    static let jointNames: [(String, VNHumanBodyPoseObservation.JointName)] = [
        ("nose", .nose), ("neck", .neck), ("root", .root),
        ("leftShoulder", .leftShoulder), ("leftElbow", .leftElbow), ("leftWrist", .leftWrist),
        ("rightShoulder", .rightShoulder), ("rightElbow", .rightElbow), ("rightWrist", .rightWrist),
        ("leftHip", .leftHip), ("leftKnee", .leftKnee), ("leftAnkle", .leftAnkle),
        ("rightHip", .rightHip), ("rightKnee", .rightKnee), ("rightAnkle", .rightAnkle)
    ]

    static func analyze(_ image: CGImage) throws -> [HumanDetection] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        let segmentation = VNGeneratePersonInstanceMaskRequest()
        let pose = VNDetectHumanBodyPoseRequest()
        let rectangles = VNDetectHumanRectanglesRequest()
        rectangles.upperBodyOnly = false
        try handler.perform([segmentation, pose, rectangles])
        guard let observation = segmentation.results?.first else { return [] }
        let context = CIContext()
        let input = CIImage(cgImage: image)
        let poses = (pose.results ?? []).map { body in
            jointNames.compactMap { name, jointName -> BodyJoint? in
                guard let joint = try? body.recognizedPoint(jointName), joint.confidence >= 0.2 else { return nil }
                return BodyJoint(name: name, point: CGPoint(x: joint.x, y: 1 - joint.y), confidence: joint.confidence)
            }
        }
        var usedPoses = Set<Int>()
        var humans: [HumanDetection] = []
        for instance in observation.allInstances {
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
            let mask = CIImage(cvPixelBuffer: buffer)
            let alignedMask = mask.transformed(by: CGAffineTransform(
                scaleX: input.extent.width / mask.extent.width,
                y: input.extent.height / mask.extent.height
            ))
            guard let maskImage = context.createCGImage(alignedMask, from: input.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()),
                  let provider = maskImage.dataProvider?.data,
                  let pixels = CFDataGetBytePtr(provider) else { continue }
            var minimumX = image.width
            var minimumY = image.height
            var maximumX = 0
            var maximumY = 0
            for row in stride(from: 0, to: image.height, by: 2) {
                for column in stride(from: 0, to: image.width, by: 2) {
                    if pixels[row * maskImage.bytesPerRow + column * 4] > 127 {
                        minimumX = min(minimumX, column)
                        maximumX = max(maximumX, column)
                        minimumY = min(minimumY, row)
                        maximumY = max(maximumY, row)
                    }
                }
            }
            guard minimumX < maximumX, minimumY < maximumY else { continue }
            let bounds = CGRect(
                x: CGFloat(minimumX) / CGFloat(image.width), y: CGFloat(minimumY) / CGFloat(image.height),
                width: CGFloat(maximumX - minimumX + 2) / CGFloat(image.width),
                height: CGFloat(maximumY - minimumY + 2) / CGFloat(image.height)
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let rankedPoses = poses.indices.filter { !usedPoses.contains($0) }.map { index in
                let score = poses[index].reduce(0) { count, joint in
                    let column = min(image.width - 1, max(0, Int(joint.point.x * CGFloat(image.width))))
                    let row = min(image.height - 1, max(0, Int(joint.point.y * CGFloat(image.height))))
                    return count + (pixels[row * maskImage.bytesPerRow + column * 4] > 100 ? 1 : 0)
                }
                return (index, score)
            }
            let match = rankedPoses.max { $0.1 < $1.1 }
            let joints: [BodyJoint]
            if let match, match.1 >= 3 {
                usedPoses.insert(match.0)
                joints = poses[match.0]
            } else {
                joints = []
            }
            let confirmedByRectangle = (rectangles.results ?? []).contains { rectangle in
                guard rectangle.confidence >= 0.5 else { return false }
                let detected = CGRect(x: rectangle.boundingBox.minX, y: 1 - rectangle.boundingBox.maxY,
                                      width: rectangle.boundingBox.width, height: rectangle.boundingBox.height)
                let overlap = detected.intersection(bounds)
                guard !overlap.isNull else { return false }
                return overlap.width * overlap.height / max(bounds.width * bounds.height, 0.0001) >= 0.3
            }
            guard joints.count >= 3 || confirmedByRectangle else { continue }
            let cutout = input.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: input.extent),
                kCIInputMaskImageKey: alignedMask
            ])
            guard let result = context.createCGImage(cutout, from: input.extent) else { continue }
            humans.append(HumanDetection(id: instance, bounds: bounds, joints: joints, cutout: result, mask: maskImage))
        }
        return humans.sorted { $0.bounds.minX < $1.bounds.minX }
    }
}
