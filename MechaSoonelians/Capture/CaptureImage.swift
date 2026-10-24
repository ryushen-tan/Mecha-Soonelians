import AVFoundation
import CoreImage
import ImageIO
import UIKit

struct CaptureDepth {
    let values: Data
    let width: Int
    let height: Int
    let metric: Bool
    let preview: UIImage

    static func from(_ data: AVDepthData) -> CaptureDepth? {
        let converted = data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let buffer = converted.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var values = Data()
        for row in 0..<height {
            values.append(base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return from(values: values, width: width, height: height, metric: data.depthDataAccuracy == .absolute)
    }

    static func from(values: Data, width: Int, height: Int, metric: Bool) -> CaptureDepth? {
        guard width > 0, height > 0, values.count == width * height * 4 else { return nil }
        let samples = values.withUnsafeBytes { bytes in
            (0..<(width * height)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        let valid = samples.filter { $0.isFinite && $0 > 0 }
        guard let minimum = valid.min(), let maximum = valid.max() else { return nil }
        let pixels = samples.map { value -> UInt8 in
            guard value.isFinite, value > 0 else { return 0 }
            return UInt8(clamping: Int(1 + 254 * (1 - (value - minimum) / max(maximum - minimum, 0.001))))
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return CaptureDepth(values: values, width: width, height: height, metric: metric, preview: UIImage(cgImage: image))
    }
}

struct CaptureImage {
    let image: UIImage
    let depth: CaptureDepth?
    var originalData: Data? = nil

    static func decode(_ data: Data) throws -> CaptureImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = CGImagePropertyOrientation(rawValue: properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1) ?? .up
        var input = CIImage(cgImage: original).oriented(orientation)
        let scale = min(1, 1600 / max(input.extent.width, input.extent.height))
        input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let normalized = CIContext().createCGImage(input, from: input.extent) else { throw CocoaError(.fileReadCorruptFile) }
        var depth: CaptureDepth?
        for kind in [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity] {
            if let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) as? [AnyHashable: Any],
               let extracted = try? AVDepthData(fromDictionaryRepresentation: auxiliary) {
                depth = CaptureDepth.from(extracted.applyingExifOrientation(orientation))
                break
            }
        }
        return CaptureImage(image: UIImage(cgImage: normalized), depth: depth, originalData: data)
    }
}
