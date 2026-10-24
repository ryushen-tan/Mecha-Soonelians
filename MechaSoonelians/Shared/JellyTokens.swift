// Hallmark · studied source: server/public/play · design-system: design.md
// Colour and type tokens, shared with the MechaSoonelians target (see project.yml).
import SwiftUI

private extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

/// Tokens shared by the native adaptation of server/public/play.
enum JellyStyle {
    static let background = Color(hex: 0xe4e7ef)
    static let ink = Color(hex: 0x141414)
    static let paper = Color(hex: 0xfbfbfb)
    static let blue = Color(hex: 0x4a63ff)
    static let muted = Color(hex: 0x6b7080)
    static let field = Color(hex: 0xf1f2f6)
    static let success = Color(hex: 0x1f8f5f)
    static let error = Color(hex: 0xc0392b)
    static let colors = [0xc6ff4a, 0x4a63ff, 0xff7d8a, 0xffb86b, 0x7df0b3, 0xd58cff].map(Color.init(hex:))
    static let colorNames = ["Lime", "Blue", "Pink", "Orange", "Mint", "Purple"]

    static func display(_ size: CGFloat) -> Font { .custom("Outfit-Thin_ExtraBold", size: size, relativeTo: .title2) }
    static func body(_ size: CGFloat = 14) -> Font { .custom("Nunito-Regular", size: size, relativeTo: .body).weight(.bold) }
}
