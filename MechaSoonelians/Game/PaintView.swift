import SwiftUI

/// Paint over yourself to blend into the background. Paint only sticks to the person,
/// and the eyedropper picks colors straight from the photo.
struct PaintView: View {
    let capture: GhostCapture
    var onDone: (Data) -> Void
    var onRetake: () -> Void

    private struct Stroke {
        var points: [CGPoint]
        var color: UIColor
        var width: CGFloat
    }

    @State private var strokes: [Stroke] = []
    @State private var color = UIColor.gray
    @State private var brushSize: CGFloat = 40
    @State private var isPicking = false
    @State private var showBackground = true

    private var imageSize: CGSize { CGSize(width: capture.photo.width, height: capture.photo.height) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let scale = min(geo.size.width / imageSize.width, geo.size.height / imageSize.height)
                let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                ZStack {
                    if showBackground {
                        Image(decorative: capture.photo, scale: 1).resizable()
                    } else {
                        Color.black
                    }
                    Image(decorative: capture.person, scale: 1).resizable()
                    Canvas { context, _ in
                        for stroke in strokes {
                            context.stroke(path(for: stroke, scale: scale), with: .color(Color(stroke.color)),
                                           style: StrokeStyle(lineWidth: stroke.width * scale, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .mask(Image(decorative: capture.person, scale: 1).resizable())
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                    if isPicking {
                        color = Self.color(at: point, in: capture.photo)
                    } else if value.translation == .zero || strokes.isEmpty {
                        strokes.append(Stroke(points: [point], color: color, width: brushSize))
                    } else {
                        strokes[strokes.count - 1].points.append(point)
                    }
                }.onEnded { _ in
                    isPicking = false
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black)

            controls
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: isPicking ? "TAP THE PHOTO TO PICK A COLOR" : "PAINT TO MATCH WHAT'S BEHIND YOU")
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(color))
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(RallyStyle.ink, lineWidth: 2))
                    .accessibilityLabel("Current color")
                toolButton("eyedropper", label: "Pick a color from the photo", active: isPicking) { isPicking.toggle() }
                ColorPicker("Color", selection: Binding(get: { Color(color) }, set: { color = UIColor($0) }))
                    .labelsHidden()
                toolButton("arrow.uturn.backward", label: "Undo", active: false) { _ = strokes.popLast() }
                    .disabled(strokes.isEmpty)
                toolButton("photo", label: "Show background", active: showBackground) { showBackground.toggle() }
            }
            HStack {
                Image(systemName: "paintbrush.pointed").accessibilityHidden(true)
                Slider(value: $brushSize, in: 5...150).tint(RallyStyle.ink)
                    .accessibilityLabel("Brush size")
            }
            Button {
                if let data = renderGhost() { onDone(data) }
            } label: { ActionLabel(text: "Place ghost") }
            .buttonStyle(PushButtonStyle())
            Button("Retake photo", action: onRetake)
                .font(RallyStyle.font(14, .semibold))
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(RallyStyle.surface)
        .foregroundStyle(RallyStyle.ink)
    }

    private func toolButton(_ systemImage: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 40)
                .background(active ? RallyStyle.lime : RallyStyle.line.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .rallyHover(cornerRadius: 12)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func path(for stroke: Stroke, scale: CGFloat) -> Path {
        var path = Path()
        let points = stroke.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first) // a dot
        }
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    /// The painted person, cropped to their outline and capped at 1024 px on the long side.
    private func renderGhost() -> Data? {
        let crop = capture.bounds
        let scale = min(1, 1024 / max(crop.width, crop.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: crop.width * scale, height: crop.height * scale), format: format)
        return renderer.pngData { context in
            let cg = context.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -crop.minX, y: -crop.minY)
            UIImage(cgImage: capture.person).draw(in: CGRect(origin: .zero, size: imageSize))
            // Paint only where the person already is.
            cg.setBlendMode(.sourceAtop)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for stroke in strokes {
                cg.setStrokeColor(stroke.color.cgColor)
                cg.setLineWidth(stroke.width)
                cg.addPath(path(for: stroke, scale: 1).cgPath)
                cg.strokePath()
            }
        }
    }

    /// Average color of a small patch of the photo, so camera noise doesn't throw it off.
    private static func color(at point: CGPoint, in image: CGImage) -> UIColor {
        let patch = 7
        var pixels = [UInt8](repeating: 0, count: patch * patch * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: patch, height: patch, bitsPerComponent: 8,
                                          bytesPerRow: patch * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Shift the image so the patch around the point lands on the context (CG's origin is bottom-left).
            let x = point.x - CGFloat(patch / 2)
            let y = CGFloat(image.height) - point.y - CGFloat(patch / 2)
            context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard drawn else { return .gray }
        var total = [0, 0, 0]
        for i in 0..<(patch * patch) {
            for c in 0..<3 { total[c] += Int(pixels[i * 4 + c]) }
        }
        let count = CGFloat(patch * patch * 255)
        return UIColor(red: CGFloat(total[0]) / count, green: CGFloat(total[1]) / count, blue: CGFloat(total[2]) / count, alpha: 1)
    }
}
