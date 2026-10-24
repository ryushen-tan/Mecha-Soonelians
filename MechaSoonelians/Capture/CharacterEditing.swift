import SwiftUI

struct CharacterEditingSettings: Codable, Equatable {
    var preset = "original"
    var tool = "orbit"
    var color = "#d4ed5e"
    var brush: Double = 0.035
    var opacity: Double = 1
    var metallic: Double = 0
    var roughness: Double = 0.8
    var shadows = true
    var room = false
    var scale: Double = 1
    var position: [Double] = [0, 0, 0]
    var rotation: [Double] = [0, 0, 0, 1]
    var frozen = false
    var form: String? = nil
    var xray: Bool? = nil

    var dictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result = value
        result["form"] = form ?? "person"
        return result
    }
}

struct CharacterPoseChoice: Identifiable {
    let id: String
    let name: String
    let icon: String

    static let pages: [[CharacterPoseChoice]] = [
        [
            .init(id: "original", name: "Original", icon: "figure.stand"),
            .init(id: "stand", name: "Stand", icon: "figure.stand"),
            .init(id: "crouch", name: "Crouch", icon: "figure.strengthtraining.functional"),
            .init(id: "sit", name: "Sit", icon: "figure.seated.seatbelt"),
            .init(id: "star", name: "Star", icon: "figure.arms.open"),
            .init(id: "reach", name: "Reach", icon: "figure.wave"),
            .init(id: "curl", name: "Curl up", icon: "figure.flexibility"),
            .init(id: "prone", name: "Lie flat", icon: "figure.core.training")
        ],
        [
            .init(id: "kneel", name: "Kneel", icon: "figure.cooldown"),
            .init(id: "side", name: "Side lie", icon: "figure.pilates"),
            .init(id: "lean", name: "Lean", icon: "figure.surfing"),
            .init(id: "backbend", name: "Backbend", icon: "figure.gymnastics"),
            .init(id: "handsUp", name: "Hands up", icon: "figure.arms.open"),
            .init(id: "balance", name: "One leg", icon: "figure.yoga"),
            .init(id: "tuck", name: "Tuck", icon: "figure.wrestling"),
            .init(id: "tpose", name: "T-pose", icon: "figure.stand.line.dotted.figure.stand")
        ]
    ]
}

struct PoseWheel: View {
    @Binding var page: Int
    @Binding var highlighted: String?
    let current: String
    var pages = CharacterPoseChoice.pages
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let choices = pages[min(page, pages.count - 1)]
            ZStack {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    let angle = Double(index) * .pi / 4 - .pi / 2
                    let selected = (highlighted ?? current) == choice.id
                    Button { onSelect(choice.id) } label: {
                        ZStack {
                            WheelSlice(index: index).fill(selected ? RallyStyle.cyan : RallyStyle.surface.opacity(0.98))
                            WheelSlice(index: index).stroke(RallyStyle.ink.opacity(0.15), lineWidth: 1)
                            VStack(spacing: 3) {
                                Image(systemName: choice.icon).font(.system(size: side * 0.085))
                                Text(choice.name).font(RallyStyle.font(max(9, side * 0.035), .semibold))
                            }
                            .position(x: side / 2 + cos(angle) * side * 0.355, y: side / 2 + sin(angle) * side * 0.355)
                        }
                        .contentShape(WheelSlice(index: index))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pose: \(choice.name)")
                    .accessibilityIdentifier("poseChoice_\(choice.id)")
                }
                Button { page = (page + 1) % pages.count; highlighted = nil } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("\(page + 1) / \(pages.count)").font(RallyStyle.font(11, .bold))
                    }
                    .frame(width: side * 0.29, height: side * 0.29)
                    .background(RallyStyle.lime, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Next pose wheel page")
            }
            .frame(width: side, height: side)
            .simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { value in highlighted = Self.choice(at: value.location, side: side, page: page, pages: pages) }
                .onEnded { value in
                    if let selected = Self.choice(at: value.location, side: side, page: page, pages: pages) { onSelect(selected) }
                    highlighted = nil
                })
        }
        .aspectRatio(1, contentMode: .fit)
        .foregroundStyle(RallyStyle.ink)
        .shadow(color: RallyStyle.ink.opacity(0.2), radius: 18, y: 6)
    }

    static func choice(at point: CGPoint, side: CGFloat, page: Int, pages: [[CharacterPoseChoice]] = CharacterPoseChoice.pages) -> String? {
        let horizontal = point.x - side / 2
        let vertical = point.y - side / 2
        let distance = hypot(horizontal, vertical)
        guard distance > side * 0.17, distance < side * 0.56 else { return nil }
        let angle = atan2(vertical, horizontal) + .pi / 2 + .pi / 8
        let normalized = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let choices = pages[min(page, pages.count - 1)]
        let slot = Int(normalized / (.pi / 4)) % 8
        return slot < choices.count ? choices[slot].id : nil
    }
}

private struct WheelSlice: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(Double(index) * 45 - 112.5)
        let end = Angle.degrees(Double(index) * 45 - 67.5)
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: radius * 0.32, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct PaintColorWheel: View {
    @Binding var hex: String
    @State private var hue: Double = 0.2
    @State private var saturation: Double = 0.7
    @State private var brightness: Double = 1

    var body: some View {
        HStack(spacing: 20) {
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                ZStack {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: side / 2))
                    Circle().fill(.black.opacity(1 - brightness))
                    Circle().stroke(.white, lineWidth: 3).background(Circle().fill(Color(hue: hue, saturation: saturation, brightness: brightness)))
                        .frame(width: 15, height: 15)
                        .offset(x: cos(hue * 2 * .pi) * saturation * side / 2, y: sin(hue * 2 * .pi) * saturation * side / 2)
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let horizontal = value.location.x - side / 2
                    let vertical = value.location.y - side / 2
                    hue = (atan2(vertical, horizontal) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                    saturation = min(1, hypot(horizontal, vertical) / (side / 2))
                    updateColor()
                })
                .accessibilityLabel("Paint color wheel")
                .accessibilityValue(hex)
                .accessibilityAdjustableAction { direction in
                    hue = (hue + (direction == .increment ? 0.05 : 0.95)).truncatingRemainder(dividingBy: 1)
                    updateColor()
                }
            }
            .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 10) {
                Text(hex.uppercased()).font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("Brightness").font(RallyStyle.font(12))
                Slider(value: $brightness, in: 0...1).onChange(of: brightness) { _, _ in updateColor() }
                    .accessibilityLabel("Paint brightness")
                HStack(spacing: 8) {
                    ForEach(["#ffffff", "#252c27", "#d4ed5e", "#a8d6eb", "#f79678"], id: \.self) { color in
                        Button { hex = color; readColor() } label: {
                            Circle().fill(Color.paintHex(color)).frame(width: 26, height: 26)
                                .overlay(Circle().stroke(RallyStyle.line))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Paint \(color)")
                    }
                }
            }
        }
        .onAppear { readColor() }
        .onChange(of: hex) { _, _ in readColor() }
    }

    private func updateColor() {
        let color = UIColor(Color(hue: hue, saturation: saturation, brightness: brightness))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        hex = String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    private func readColor() {
        var newHue: CGFloat = 0, newSaturation: CGFloat = 0, newBrightness: CGFloat = 0
        UIColor(Color.paintHex(hex)).getHue(&newHue, saturation: &newSaturation, brightness: &newBrightness, alpha: nil)
        hue = Double(newHue); saturation = Double(newSaturation); brightness = Double(newBrightness)
    }
}

extension Color {
    static func paintHex(_ hex: String) -> Color {
        let value = Int(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xffffff
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
