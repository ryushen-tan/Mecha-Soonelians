// Run from the repository root:
// swiftc Rally/ProfileAvatarMesh.swift Tools/ProfileAvatars/main.swift -o /tmp/rally-profile-avatars
// /tmp/rally-profile-avatars Rally/ProfilePhotos
import AppKit
import SceneKit
import Vision
import ImageIO
import Metal

struct Profile: Decodable { let name: String; let file: String }
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Rally/ProfilePhotos")
let output = root.appendingPathComponent("Avatars", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let profiles = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: root.appendingPathComponent("profiles.json")))
let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "AvatarExport", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "AvatarExport", code: 2) }
}

/// Project the portrait over the front hemisphere and extend its edge colors
/// around the rear. Unseen sides never receive a second, mirrored face.
func wrappedHeadTexture(_ photo: CGImage) throws -> CGImage {
    let size = 512, width = 1024, height = 512
    let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let source = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format),
          let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format),
          let sourceBytes = source.data?.assumingMemoryBound(to: UInt8.self),
          let pixels = result.data?.assumingMemoryBound(to: UInt8.self) else {
        throw NSError(domain: "AvatarTexture", code: 1)
    }
    source.interpolationQuality = .high
    source.draw(photo, in: CGRect(x: 0, y: 0, width: size, height: size))
    func sample(_ x: Double, _ y: Double, _ channel: Int) -> Double {
        let px = min(Double(size - 1), max(0, x * Double(size - 1)))
        let py = min(Double(size - 1), max(0, y * Double(size - 1)))
        let x0 = Int(px), y0 = Int(py), x1 = min(size - 1, x0 + 1), y1 = min(size - 1, y0 + 1)
        let fx = px - Double(x0), fy = py - Double(y0)
        func value(_ x: Int, _ y: Int) -> Double { Double(sourceBytes[(y * size + x) * 4 + channel]) }
        return (value(x0, y0) * (1 - fx) + value(x1, y0) * fx) * (1 - fy)
            + (value(x0, y1) * (1 - fx) + value(x1, y1) * fx) * fy
    }
    for row in 0..<height {
        let pitch = (0.5 - Double(row) / Double(height - 1)) * Double.pi
        let y = 0.5 - 0.5 * sin(pitch)
        // Follow an oval within the portrait to avoid wrapping its rectangular background.
        let radius = max(0.035, 0.47 * sqrt(max(0, 1 - pow(2 * y - 1, 2))))
        var left = [Double](repeating: 0, count: 3), right = left
        for channel in 0..<3 {
            for offset in -12...12 {
                let sampleY = y + Double(offset) / Double(size)
                left[channel] += sample(0.5 - radius * 0.90, sampleY, channel) / 25
                right[channel] += sample(0.5 + radius * 0.90, sampleY, channel) / 25
            }
        }
        for column in 0..<width {
            let yaw = (Double(column) / Double(width - 1) - 0.5) * 2 * Double.pi
            let side = (sin(yaw) + 1) / 2
            let blend = min(1, max(0, (abs(yaw) - 1.15) / 0.42))
            let smooth = blend * blend * (3 - 2 * blend)
            for channel in 0..<3 {
                let face = sample(0.5 + sin(yaw) * radius, y, channel)
                let edge = left[channel] * (1 - side) + right[channel] * side
                pixels[(row * width + column) * 4 + channel] = UInt8(min(255, max(0, face * (1 - smooth) + edge * smooth)))
            }
            pixels[(row * width + column) * 4 + 3] = 255
        }
    }
    return result.makeImage()!
}

for profile in profiles {
    try autoreleasepool {
        let url = root.appendingPathComponent(profile.file)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw NSError(domain: "AvatarInput", code: 1) }
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: photo).perform([request])
        let faces = (request.results ?? []).sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        guard faces.count == 1, let bounds = faces.first?.boundingBox else {
            throw NSError(domain: "AvatarInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "Review face selection for \(profile.name): \(faces.count) faces"])
        }
        // Vision's box includes the face. Extend above it to retain the hairline.
        let w = CGFloat(photo.width), h = CGFloat(photo.height)
        let crop = CGRect(x: (bounds.minX - bounds.width * 0.10) * w,
                          y: (1 - bounds.maxY - bounds.height * 0.28) * h,
                          width: bounds.width * 1.20 * w, height: bounds.height * 1.38 * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard let cropped = photo.cropping(to: crop) else {
            throw NSError(domain: "AvatarTexture", code: 1)
        }
        let texture = try wrappedHeadTexture(cropped)
        let stem = url.deletingPathExtension().lastPathComponent
        try writePNG(texture, to: output.appendingPathComponent(stem + "-face.png"))
        let scene = ProfileAvatarMesh.scene(texture: texture)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "avatar-camera", recursively: false)
        let snapshot = renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 512), antialiasingMode: .multisampling4X)
        var rect = CGRect(x: 0, y: 0, width: 512, height: 512)
        guard let rendered = snapshot.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw NSError(domain: "AvatarRender", code: 1)
        }
        try writePNG(rendered, to: output.appendingPathComponent(stem + ".png"))
        print("Generated \(profile.name)")
    }
}
