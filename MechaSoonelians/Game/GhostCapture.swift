import ARKit
import CoreImage
import RealityKit
import Vision

/// A hider's photo, cut out of its background and placed where they stood in the house.
struct GhostCapture {
    /// The whole photo, upright.
    let photo: CGImage
    /// Just the person, transparent elsewhere. Same size as `photo`.
    let person: CGImage
    /// Where the person is in the photo, in pixels from the top-left.
    let bounds: CGRect
    /// The ghost's pose in house coordinates: centered on the person, facing the camera.
    let transform: simd_float4x4
    let width: Float
    let height: Float

    enum CaptureError: LocalizedError {
        case noPerson, noPlacement

        var errorDescription: String? {
            switch self {
            case .noPerson: "Couldn't find a person in the photo. Try again with your whole body in view."
            case .noPlacement: "Couldn't work out where you were standing. Make sure your feet are in the photo."
            }
        }
    }

    static func make(from frame: ARFrame, floorY: Float) throws -> GhostCapture {
        let orientation = uprightOrientation(of: frame.camera)
        let context = CIContext()
        let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(orientation)
        guard let photo = context.createCGImage(upright, from: upright.extent) else { throw CaptureError.noPerson }

        // Cut the person out.
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
        guard let person = context.createCGImage(cutout, from: CGRect(x: 0, y: 0, width: photo.width, height: photo.height)) else {
            throw CaptureError.noPerson
        }

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

        // A plane faces +Z; turn it toward where the photo was taken.
        let yaw = atan2(toCamera.x, toCamera.z)
        let transform = Transform(
            rotation: simd_quatf(angle: yaw, axis: up),
            translation: feet + up * (height / 2)
        ).matrix

        return GhostCapture(photo: photo, person: person, bounds: bounds, transform: transform, width: width, height: height)
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
