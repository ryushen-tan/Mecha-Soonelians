// Hallmark · studied source: server/public/play · design-system: design.md
// Pre-emit critique: P5 H4 E4 S5 R4 V4. Native adaptation; source fidelity takes priority.
import SwiftUI

struct JellyButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, dark, danger }
    var kind: Kind = .primary
    var fullWidth = false
    @Environment(\.isEnabled) private var enabled
    @EnvironmentObject private var audio: JellyAudio

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(JellyStyle.body())
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .foregroundStyle(kind == .ghost ? JellyStyle.ink : .white)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(kind == .ghost ? JellyStyle.ink : .clear, lineWidth: 2))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .hoverEffect(.highlight)
            .onChange(of: configuration.isPressed) { _, pressed in if pressed { audio.key(.click) } }
    }

    private var fill: Color {
        switch kind {
        case .primary: JellyStyle.blue
        case .ghost: JellyStyle.paper
        case .dark: JellyStyle.ink
        case .danger: JellyStyle.error
        }
    }
}

struct JellyCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(24).frame(maxWidth: 440)
            .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(JellyStyle.ink, lineWidth: 2))
            .compositingGroup()
            .shadow(color: JellyStyle.ink.opacity(0.2), radius: 24, y: 16)
    }
}

struct JellyField: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content.padding(14)
            .background(JellyStyle.field, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? JellyStyle.blue : JellyStyle.ink, lineWidth: 2))
    }
}

struct JellyNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(JellyStyle.body(13)).foregroundStyle(JellyStyle.error)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("lobbyError")
    }
}
