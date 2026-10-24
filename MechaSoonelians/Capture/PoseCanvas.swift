import SpriteKit
import SwiftUI
import CoreImage

final class HumanPoseScene: SKScene {
    private let person = SKNode()
    private let skeleton = SKNode()
    private var parts: [String: SKSpriteNode] = [:]
    private var displaySize = CGSize.zero
    private(set) var rig: BodyRig?

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .aspectFit
        addChild(person)
        addChild(skeleton)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    func configure(image: CGImage, joints: [BodyJoint]) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let newRig = BodyRig(joints: joints, imageSize: imageSize)
        rig = newRig
        let scale = min(size.width / imageSize.width, size.height / imageSize.height) * 0.72
        displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        person.removeAllChildren()
        parts = [:]
        for (bone, texture) in makeBodyParts(image: image, rig: newRig) {
            let part = SKSpriteNode(texture: SKTexture(cgImage: texture))
            part.size = displaySize
            parts[bone] = part
            person.addChild(part)
        }
        updatePose(angles: [:], showsSkeleton: true)
    }

    func updatePose(angles: [String: Double], showsSkeleton: Bool) {
        guard let rig else { return }
        let transforms = rig.transforms(angles: angles)
        let center = CGPoint(x: rig.imageSize.width / 2, y: rig.imageSize.height / 2)
        for (bone, part) in parts {
            let transform = transforms[bone] ?? .identity
            part.position = scenePoint(center.applying(transform), imageSize: rig.imageSize)
            part.zRotation = -atan2(transform.b, transform.a)
        }
        skeleton.removeAllChildren()
        skeleton.isHidden = !showsSkeleton
        let posed = rig.posedPoints(angles: angles)
        for bone in rig.bones {
            guard let start = posed[bone.start], let end = posed[bone.end] else { continue }
            let path = CGMutablePath()
            path.move(to: scenePoint(start, imageSize: rig.imageSize))
            path.addLine(to: scenePoint(end, imageSize: rig.imageSize))
            let line = SKShapeNode(path: path)
            line.strokeColor = UIColor(RallyStyle.lime)
            line.lineWidth = 3
            skeleton.addChild(line)
        }
        for point in posed.values {
            let dot = SKShapeNode(circleOfRadius: 5)
            dot.fillColor = .white
            dot.strokeColor = .black
            dot.lineWidth = 1.5
            dot.position = scenePoint(point, imageSize: rig.imageSize)
            skeleton.addChild(dot)
        }
    }

    func exportImage() -> UIImage? {
        guard let view else { return nil }
        let wasHidden = skeleton.isHidden
        skeleton.isHidden = true
        defer { skeleton.isHidden = wasHidden }
        guard let texture = view.texture(from: self, crop: CGRect(origin: .zero, size: size)) else { return nil }
        return UIImage(cgImage: texture.cgImage())
    }

    private func scenePoint(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + (point.x / imageSize.width - 0.5) * displaySize.width,
                y: size.height / 2 + (0.5 - point.y / imageSize.height) * displaySize.height)
    }

    private func makeBodyParts(image: CGImage, rig: BodyRig) -> [(String, CGImage)] {
        let context = CIContext()
        let input = CIImage(cgImage: image)
        guard let rgba = context.createCGImage(input, from: input.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()),
              let data = rgba.dataProvider?.data, let pixels = CFDataGetBytePtr(data) else { return [] }
        let bones = rig.bones
        let points = rig.points
        let segments = bones.compactMap { bone -> (RigBone, CGPoint, CGPoint)? in
            guard let start = points[bone.start], let end = points[bone.end] else { return nil }
            return (bone, start, end)
        }
        guard !segments.isEmpty else { return [] }
        let rowBytes = image.width * 4
        var buffers = segments.map { _ in [UInt8](repeating: 0, count: rowBytes * image.height) }
        for row in 0..<image.height {
            for column in 0..<image.width {
                let sourceOffset = row * rgba.bytesPerRow + column * 4
                guard pixels[sourceOffset + 3] > 0 else { continue }
                let point = CGPoint(x: column, y: row)
                var closest = 0
                var minimum = CGFloat.greatestFiniteMagnitude
                for (index, segment) in segments.enumerated() {
                    let distance = rig.distanceToSegment(point, start: segment.1, end: segment.2)
                    if distance < minimum { minimum = distance; closest = index }
                }
                let offset = row * rowBytes + column * 4
                for component in 0..<4 { buffers[closest][offset + component] = pixels[sourceOffset + component] }
            }
        }
        return segments.indices.compactMap { index in
            guard let provider = CGDataProvider(data: Data(buffers[index]) as CFData),
                  let piece = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: rowBytes, space: rgba.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: rgba.bitmapInfo, provider: provider, decode: nil,
                                      shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return (segments[index].0.id, piece)
        }
    }
}

struct PoseCanvas: UIViewRepresentable {
    let scene: HumanPoseScene
    var angles: [String: Double]
    var showsSkeleton: Bool

    func makeUIView(context: Context) -> SKView {
        let view = SKView()
        view.allowsTransparency = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.presentScene(scene)
        return view
    }

    func updateUIView(_ view: SKView, context: Context) {
        scene.updatePose(angles: angles, showsSkeleton: showsSkeleton)
    }
}
