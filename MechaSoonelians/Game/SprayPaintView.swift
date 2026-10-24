import SwiftUI

/// The hiding controls over the AR view: a + in the middle, and one big button that picks up the
/// color under the + from the real room, or sprays while held when the + is on the body. A pose
/// button cycles poses, and a joystick and turn buttons walk the chameleon around.
struct SprayPaintView: View {
    @ObservedObject var painter: SprayPainter
    let timeLeft: String
    var onHide: () -> Void
    var onCancel: () -> Void

    /// Whether the current press is spraying (it started on the body) rather than picking.
    @State private var pressing = false

    private var sprayMode: Bool { painter.isSpraying || painter.aimingAtBody }

    var body: some View {
        ZStack {
            crosshair
            VStack(spacing: 0) {
                topBar
                Spacer()
                moveControls
                bottomPanel
            }
        }
    }

    private var hint: String {
        if !painter.isReady { return "Putting your chameleon in the room…" }
        if !painter.hasPickedColor { return "Point the + at the wall behind your chameleon and tap Pick." }
        if painter.isSpraying { return "Move the phone to spray. Step closer for detail, back for big areas." }
        return sprayMode ? "Hold to spray. Point at the wall again for a new color." : "Point the + at your chameleon to spray, or tap Pick for a new color."
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "SPRAY PAINT · \(timeLeft)")
                Text(hint)
                    .font(RallyStyle.font(14, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            roundButton("arrow.uturn.backward", label: "Undo") { painter.undo() }
                .disabled(!painter.canUndo)
                .opacity(painter.canUndo ? 1 : 0.4)
            Button { painter.nextPose() } label: {
                VStack(spacing: 2) {
                    Image(systemName: painter.poseIcon).font(.system(size: 20, weight: .semibold))
                    Text(painter.poseName).font(RallyStyle.font(10, .semibold)).lineLimit(1)
                }
                .frame(width: 64, height: 50)
                .background(RallyStyle.lime, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pose: \(painter.poseName)")
            .accessibilityHint("Switches to the next pose.")
        }
        .padding(14)
        .background(RallyStyle.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var crosshair: some View {
        ZStack {
            Circle()
                .stroke(Color(painter.color), lineWidth: 5)
                .frame(width: 44, height: 44)
            Circle()
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
                .frame(width: 50, height: 50)
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2)
        }
        .scaleEffect(painter.isSpraying ? 0.85 : 1)
        .animation(.easeOut(duration: 0.12), value: painter.isSpraying)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if let error = painter.error { ErrorNotice(message: error) }
            HStack(spacing: 10) {
                Image(systemName: "circle.fill").font(.system(size: 6)).accessibilityHidden(true)
                Slider(value: $painter.spread, in: 0...1).tint(RallyStyle.ink)
                    .accessibilityLabel("Spray size")
                Image(systemName: "circle.fill").font(.system(size: 18)).accessibilityHidden(true)
            }
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(painter.color))
                    .frame(width: 56, height: 56)
                    .overlay(Circle().stroke(RallyStyle.ink, lineWidth: 2))
                    .accessibilityLabel(painter.hasPickedColor ? "Current color" : "No color picked yet")
                actionButton
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .font(RallyStyle.font(14, .semibold))
                Spacer()
                Button { onHide() } label: { ActionLabel(text: "Hide here") }
                    .buttonStyle(PushButtonStyle(dark: true))
                    .frame(maxWidth: 200)
                    .disabled(!painter.isReady)
            }
        }
        .padding(16)
        .background(RallyStyle.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// The joystick walks the chameleon across the floor the way the phone faces; the arrows turn it.
    private var moveControls: some View {
        HStack(alignment: .bottom) {
            Joystick { painter.joystick = $0 }
            Spacer()
            HStack(spacing: 10) {
                holdButton("arrow.counterclockwise", label: "Turn left") { painter.turning = $0 ? -1 : 0 }
                holdButton("arrow.clockwise", label: "Turn right") { painter.turning = $0 ? 1 : 0 }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .opacity(painter.isReady ? 1 : 0.5)
        .disabled(!painter.isReady)
    }

    /// One button for both jobs, so the player never has to look away from the +.
    private var actionButton: some View {
        HStack(spacing: 10) {
            Image(systemName: sprayMode ? "paintbrush.pointed.fill" : "eyedropper.halffull")
                .font(.system(size: 22, weight: .semibold))
            Text(painter.isSpraying ? "Spraying…" : sprayMode ? "Hold to spray" : "Pick")
                .font(RallyStyle.font(20, .bold))
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .foregroundStyle(RallyStyle.ink)
        .background(sprayMode ? RallyStyle.lime : RallyStyle.cyan, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.ink, lineWidth: 2))
        .opacity(painter.isReady ? 1 : 0.5)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard painter.isReady, !pressing else { return }
                pressing = true
                if painter.aimingAtBody {
                    painter.isSpraying = true
                } else {
                    painter.pickColor()
                }
            }
            .onEnded { _ in
                pressing = false
                painter.isSpraying = false
            })
        .accessibilityElement()
        .accessibilityLabel(sprayMode ? "Spray" : "Pick color")
        .accessibilityHint(sprayMode ? "Hold to spray where the plus points." : "Picks the color under the plus.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if painter.aimingAtBody {
                painter.isSpraying = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    painter.isSpraying = false
                }
            } else {
                painter.pickColor()
            }
        }
    }

    /// A button that does something for as long as it's held.
    private func holdButton(_ systemImage: String, label: String, onHold: @escaping (Bool) -> Void) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .bold))
            .frame(width: 56, height: 56)
            .background(RallyStyle.surface.opacity(0.92), in: Circle())
            .overlay(Circle().stroke(RallyStyle.ink, lineWidth: 2))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in onHold(true) }
                .onEnded { _ in onHold(false) })
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onHold(true)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    onHold(false)
                }
            }
    }

    private func roundButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(RallyStyle.line.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A thumb stick: reports where the knob is, each axis -1...1 with up positive, and springs back
/// to the middle on release.
private struct Joystick: View {
    var onChange: (SIMD2<Float>) -> Void
    @State private var knob = CGSize.zero
    private let radius: CGFloat = 52

    var body: some View {
        ZStack {
            Circle()
                .fill(RallyStyle.surface.opacity(0.75))
                .overlay(Circle().stroke(RallyStyle.ink, lineWidth: 2))
                .frame(width: radius * 2, height: radius * 2)
            Image(systemName: "figure.walk")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RallyStyle.muted)
                .offset(y: -radius + 14)
                .accessibilityHidden(true)
            Circle()
                .fill(RallyStyle.lime)
                .overlay(Circle().stroke(RallyStyle.ink, lineWidth: 2))
                .frame(width: 46, height: 46)
                .offset(knob)
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let x = drag.location.x - radius, y = drag.location.y - radius
                let length = max(1, (x * x + y * y).squareRoot())
                let scale = min(1, radius / length)
                knob = CGSize(width: x * scale, height: y * scale)
                onChange(SIMD2(Float(knob.width / radius), Float(-knob.height / radius)))
            }
            .onEnded { _ in
                knob = .zero
                onChange(.zero)
            })
        .accessibilityElement()
        .accessibilityLabel("Move your chameleon")
        .accessibilityAdjustableAction { direction in
            onChange(SIMD2(0, direction == .increment ? 1 : -1))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                onChange(.zero)
            }
        }
    }
}
