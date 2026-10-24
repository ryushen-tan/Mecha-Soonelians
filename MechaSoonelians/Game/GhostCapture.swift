import ARKit
import CoreImage
import RealityKit
import UIKit
import Vision

/// Where a ghost goes in the house, however it was made.
struct GhostPlacement {
    /// Center of a flat cutout.
    let transform: simd_float4x4
    /// Where a 3D ghost stands: on the floor, +Z facing out.
    let floorTransform: simd_float4x4
    /// The 3D ghost's back goes against a wall at `floorTransform`.
    let flushBack: Bool
    let width: Float
    let height: Float

    /// A ghost standing at `origin` on the floor and facing `facing`.
    init(origin: SIMD3<Float>, facing: SIMD3<Float>, onWall: Bool, width: Float, height: Float) {
        let up = SIMD3<Float>(0, 1, 0)
        let rotation = simd_quatf(angle: atan2(facing.x, facing.z), axis: up)
        floorTransform = Transform(rotation: rotation, translation: origin).matrix
        // A flat ghost on a wall sits just off it so the wall doesn't hide it.
        transform = Transform(rotation: rotation, translation: origin + up * (height / 2) + (onWall ? facing * 0.02 : .zero)).matrix
        flushBack = onWall
        self.width = width
        self.height = height
    }

    /// The same ghost slid along the floor by `offset` and turned by `turn` radians.
    func moved(by offset: SIMD3<Float>, turn: Float) -> GhostPlacement {
        let origin = simd_make_float3(floorTransform.columns.3) + SIMD3(offset.x, 0, offset.z)
        let facing = simd_quatf(angle: turn, axis: [0, 1, 0]).act(simd_make_float3(floorTransform.columns.2))
        return GhostPlacement(origin: origin, facing: facing, onWall: flushBack, width: width, height: height)
    }
}

/// A hider's photo, cut out of its background and placed where they stood in the house.
struct GhostCapture {
    /// The whole photo, upright.
    let photo: CGImage
    /// Just the person, transparent elsewhere. Same size as `photo`.
    let person: CGImage
    /// Where the person is in the photo, in pixels from the top-left.
    let bounds: CGRect
    /// Where they stood: on the nearest wall within a metre (back against it), else facing the camera.
    let placement: GhostPlacement

    /// A scanned wall: its plane is the transform's x-y plane, `width` along x.
    struct Wall {
        let transform: simd_float4x4
        let width: Float
    }

    enum CaptureError: LocalizedError {
        case noPerson, noPlacement

        var errorDescription: String? {
            switch self {
            case .noPerson: "Couldn't find a person in the photo. Try again with your whole body in view."
            case .noPlacement: "Couldn't work out where you were standing. Make sure your feet are in the photo."
            }
        }
    }

    /// The current AR camera image, turned upright.
    static func uprightPhoto(from frame: ARFrame) -> CGImage? {
        let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(uprightOrientation(of: frame.camera))
        return CIContext().createCGImage(upright, from: upright.extent)
    }

    /// Cuts the most prominent person out of an upright photo. `person` is the photo with
    /// everything else transparent; `bounds` is their box in pixels from the top-left.
    static func cutOut(_ photo: CGImage) throws -> (person: CGImage, bounds: CGRect) {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: photo).perform([request])
        guard let mask = request.results?.first?.pixelBuffer,
              let maskBounds = personBounds(in: mask) else { throw CaptureError.noPerson }

        let scaleX = CGFloat(photo.width) / CGFloat(CVPixelBufferGetWidth(mask))
        let scaleY = CGFloat(photo.height) / CGFloat(CVPixelBufferGetHeight(mask))
        let bounds = maskBounds.applying(CGAffineTransform(scaleX: scaleX, y: scaleY)).integral
            .intersection(CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
        let fullMask = CIImage(cvPixelBuffer: mask).transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let cutout = CIImage(cgImage: photo).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: fullMask,
        ])
        guard let person = CIContext().createCGImage(cutout, from: CGRect(x: 0, y: 0, width: photo.width, height: photo.height)) else {
            throw CaptureError.noPerson
        }
        return (person, bounds)
    }

    static func make(from frame: ARFrame, floorY: Float, walls: [Wall]) throws -> GhostCapture {
        let orientation = uprightOrientation(of: frame.camera)
        guard let photo = uprightPhoto(from: frame) else { throw CaptureError.noPerson }
        let (person, bounds) = try cutOut(photo)

        // Find the feet on the floor, then measure the person on an upright plane through the feet.
        let viewport = CGSize(width: photo.width, height: photo.height)
        let interface = interfaceOrientation(for: orientation)
        var floor = matrix_identity_float4x4
        floor.columns.3.y = floorY
        guard let feet = frame.camera.unprojectPoint(CGPoint(x: bounds.midX, y: bounds.maxY), ontoPlane: floor,
                                                     orientation: interface, viewportSize: viewport) else {
            throw CaptureError.noPlacement
        }
        let cameraPosition = simd_make_float3(frame.camera.transform.columns.3)
        var toCamera = cameraPosition - feet
        toCamera.y = 0
        guard simd_length(toCamera) > 0.2 else { throw CaptureError.noPlacement }
        toCamera = simd_normalize(toCamera)

        // unprojectPoint projects onto the plane's x-z plane, so its y axis is the normal.
        let up = SIMD3<Float>(0, 1, 0)
        let standing = simd_float4x4(
            SIMD4(simd_cross(toCamera, up), 0),
            SIMD4(toCamera, 0),
            SIMD4(up, 0),
            SIMD4(feet, 1)
        )
        guard let head = frame.camera.unprojectPoint(CGPoint(x: bounds.midX, y: bounds.minY), ontoPlane: standing,
                                                     orientation: interface, viewportSize: viewport) else {
            throw CaptureError.noPlacement
        }
        let height = head.y - feet.y
        guard height > 0.3, height < 3 else { throw CaptureError.noPlacement }
        let width = height * Float(bounds.width / bounds.height)

        // Ghosts face +Z: toward where the photo was taken, or out from a wall right behind the person.
        var origin = feet
        var facing = toCamera
        let wall = nearestWall(to: feet, from: cameraPosition, walls: walls)
        if let wall {
            origin = SIMD3(wall.point.x, feet.y, wall.point.z)
            facing = wall.normal
        }
        let placement = GhostPlacement(origin: origin, facing: facing, onWall: wall != nil, width: width, height: height)
        return GhostCapture(photo: photo, person: person, bounds: bounds, placement: placement)
    }

    /// The person on a transparent background with some margin, the way Tripo likes its input.
    func cutoutPNG() -> Data? {
        let margin = max(bounds.width, bounds.height) * 0.1
        let crop = bounds.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
        let scale = min(1, 1536 / max(crop.width, crop.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: crop.width * scale, height: crop.height * scale), format: format)
            .pngData { context in
                context.cgContext.scaleBy(x: scale, y: scale)
                context.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
                UIImage(cgImage: person).draw(in: CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
            }
    }

    /// The unpainted person cropped to their outline, shown until a 3D ghost arrives on other phones.
    func flatCutoutPNG() -> Data? {
        let scale = min(1, 1024 / max(bounds.width, bounds.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: bounds.width * scale, height: bounds.height * scale), format: format)
            .pngData { context in
                context.cgContext.scaleBy(x: scale, y: scale)
                context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                UIImage(cgImage: person).draw(in: CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
            }
    }

    /// The closest wall within a metre of the feet, if the feet are in front of it (not past its ends).
    /// The returned normal points into the room, toward the camera.
    private static func nearestWall(to feet: SIMD3<Float>, from camera: SIMD3<Float>, walls: [Wall]) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        var best: (point: SIMD3<Float>, normal: SIMD3<Float>, distance: Float)?
        for wall in walls {
            let center = simd_make_float3(wall.transform.columns.3)
            var normal = simd_make_float3(wall.transform.columns.2)
            normal.y = 0
            guard simd_length(normal) > 0.5 else { continue }
            normal = simd_normalize(normal)
            let along = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), normal))
            let offset = feet - center
            let distance = abs(simd_dot(offset, normal))
            guard distance < 1, abs(simd_dot(offset, along)) < wall.width / 2 + 0.3,
                  distance < best?.distance ?? .infinity else { continue }
            if simd_dot(camera - center, normal) < 0 { normal = -normal }
            best = (feet - normal * simd_dot(offset, normal), normal, distance)
        }
        return best.map { ($0.point, $0.normal) }
    }

    /// Which way to turn the camera image so the room is upright, from the direction of gravity.
    private static func uprightOrientation(of camera: ARCamera) -> CGImagePropertyOrientation {
        // Gravity in camera space. The camera image's x runs along camera +x, its y along camera -y.
        let rotation = simd_float3x3(
            simd_make_float3(camera.transform.columns.0),
            simd_make_float3(camera.transform.columns.1),
            simd_make_float3(camera.transform.columns.2)
        )
        let gravity = rotation.transpose * SIMD3<Float>(0, -1, 0)
        let right = gravity.x, down = -gravity.y
        if abs(right) > abs(down) {
            return right > 0 ? .right : .left
        }
        return down > 0 ? .up : .down
    }

    private static func interfaceOrientation(for orientation: CGImagePropertyOrientation) -> UIInterfaceOrientation {
        switch orientation {
        case .right: .portrait
        case .left: .portraitUpsideDown
        case .down: .landscapeLeft
        default: .landscapeRight
        }
    }

    /// Bounding box of the mask's person pixels, in mask pixels from the top-left.
    private static func personBounds(in mask: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = pixels + y * rowBytes
            for x in 0..<width where row[x] > 127 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
