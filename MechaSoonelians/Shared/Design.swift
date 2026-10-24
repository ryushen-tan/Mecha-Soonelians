import SwiftUI

// Hallmark · Hum adapted to native task flows · SF Rounded / SF Mono
// Pre-emit critique: philosophy 4, hierarchy 5, execution 4, specificity 5, restraint 4, variety 4.
enum RallyStyle {
    static let paper = Color(red: 0.975, green: 0.969, blue: 0.943)
    static let surface = Color(red: 1, green: 0.997, blue: 0.980)
    static let ink = Color(red: 0.12, green: 0.16, blue: 0.14)
    static let muted = Color(red: 0.40, green: 0.43, blue: 0.39)
    static let line = Color(red: 0.85, green: 0.86, blue: 0.81)
    static let lime = Color(red: 0.83, green: 0.93, blue: 0.37)
    static let limeEdge = Color(red: 0.64, green: 0.74, blue: 0.24)
    static let cyan = Color(red: 0.66, green: 0.84, blue: 0.92)
    static let coral = Color(red: 0.97, green: 0.59, blue: 0.47)
    static let lavender = Color(red: 0.79, green: 0.73, blue: 0.94)
    static let mint = Color(red: 0.70, green: 0.85, blue: 0.69)
    static let peach = Color(red: 0.97, green: 0.79, blue: 0.59)
    static let success = Color(red: 0.20, green: 0.36, blue: 0.19)
    static let error = Color(red: 0.64, green: 0.19, blue: 0.16)
    static let avatarColors = [lime, cyan, coral, lavender, mint, peach]
    static let avatarNames = ["Sunny", "Cool", "Peppy", "Dreamer", "Sprout", "Peach"]

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct PushButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var dark = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RallyStyle.font(17, .bold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(dark ? RallyStyle.paper : RallyStyle.ink)
            .background(dark ? RallyStyle.ink : destructive ? RallyStyle.coral : RallyStyle.lime, in: RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .rallyHover(cornerRadius: 16, color: dark ? RallyStyle.paper : RallyStyle.ink)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.8).foregroundStyle(RallyStyle.muted)
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "asterisk").font(.system(size: 27, weight: .black))
                .rotationEffect(.degrees(10)).foregroundStyle(RallyStyle.ink)
            Text(Self.wordmark).font(RallyStyle.font(30, .heavy)).tracking(-1.5)
            .lineLimit(1).minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mecha Soonelians")
    }

    /// "Mecha Soonelians" with one colour per letter.
    private static let wordmark: AttributedString = {
        let colors: [Color] = [
            RallyStyle.coral, RallyStyle.limeEdge, Color(red: 0.29, green: 0.39, blue: 1),
            Color(red: 0.95, green: 0.6, blue: 0.25), Color(red: 0.2, green: 0.62, blue: 0.45), Color(red: 0.62, green: 0.4, blue: 0.9)
        ]
        return "Mecha Soonelians".enumerated().reduce(into: AttributedString()) { line, letter in
            var piece = AttributedString(String(letter.element))
            piece.foregroundColor = colors[letter.offset % colors.count]
            line += piece
        }
    }()
}

struct AvatarView: View {
    let index: Int
    var size: CGFloat = 56
    var selected = false
    private var safeIndex: Int { min(5, max(0, index)) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * (safeIndex % 2 == 0 ? 0.34 : 0.5))
                .fill(RallyStyle.avatarColors[safeIndex])
            VStack(spacing: size * 0.08) {
                HStack(spacing: size * 0.15) {
                    eye
                    eye
                }
                if safeIndex == 2 || safeIndex == 5 {
                    Ellipse().fill(RallyStyle.ink).frame(width: size * 0.14, height: size * 0.17)
                } else {
                    Smile().stroke(RallyStyle.ink, style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                        .frame(width: size * 0.24, height: size * 0.11)
                }
            }
            .offset(y: size * 0.05)
        }
        .frame(width: size, height: size)
        .padding(selected ? 4 : 0)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: size * 0.38 + 4).stroke(RallyStyle.ink, lineWidth: 2)
            }
        }
        .accessibilityLabel(RallyStyle.avatarNames[safeIndex] + " avatar")
    }

    private var eye: some View {
        Capsule().fill(RallyStyle.ink)
            .frame(width: size * (safeIndex == 1 ? 0.22 : 0.055), height: size * (safeIndex == 1 ? 0.09 : 0.115))
    }
}

private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: 0), control: CGPoint(x: rect.midX, y: rect.height * 1.8))
        return path
    }
}

struct CrewIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        ZStack {
            Ellipse().fill(RallyStyle.line.opacity(0.35)).frame(width: 240, height: 20).offset(y: 53)
            AvatarView(index: 1, size: 86).rotationEffect(.degrees(-14)).offset(x: -90, y: arrived ? 4 : 14)
            AvatarView(index: 2, size: 86).rotationEffect(.degrees(14)).offset(x: 90, y: arrived ? 4 : 14)
            AvatarView(index: 0, size: 108).rotationEffect(.degrees(-4)).offset(y: arrived ? -6 : 6)
            Image(systemName: "sparkle").font(.system(size: 23, weight: .semibold))
                .foregroundStyle(RallyStyle.ink).offset(x: 132, y: -52)
            Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                .foregroundStyle(RallyStyle.muted).rotationEffect(.degrees(15)).offset(x: -138, y: -38)
        }
        .frame(maxWidth: .infinity).frame(height: 146)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.7)) { arrived = true }
        }
    }
}

struct ErrorNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(RallyStyle.font(14, .medium)).foregroundStyle(RallyStyle.error)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RallyStyle.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("errorNotice")
    }
}

extension View {
    func rallyField() -> some View {
        self.padding(16).frame(minHeight: 56)
            .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(RallyStyle.line, lineWidth: 1))
    }
}

struct ActionLabel: View {
    let text: String
    var busy = false
    var body: some View {
        HStack {
            Text(text)
            Spacer()
            if busy { ProgressView() } else { Image(systemName: "arrow.right").accessibilityHidden(true) }
        }.padding(.horizontal, 20)
    }
}

private struct GlassNavigation: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(RallyStyle.surface, in: Capsule())
                .overlay(Capsule().stroke(RallyStyle.line, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 1))
                .shadow(color: RallyStyle.ink.opacity(0.08), radius: 8, y: 4)
        }
    }
}

extension View {
    func rallyGlass() -> some View { modifier(GlassNavigation()) }
}

private struct ButtonHoverIndicator: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let cornerRadius: CGFloat
    let color: Color

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color.opacity(hovering && enabled ? 0.07 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

struct HoverButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8).frame(minHeight: 44)
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .rallyHover()
    }
}

extension View {
    func rallyHover(cornerRadius: CGFloat = 12, color: Color = RallyStyle.ink) -> some View {
        modifier(ButtonHoverIndicator(cornerRadius: cornerRadius, color: color))
    }
}
