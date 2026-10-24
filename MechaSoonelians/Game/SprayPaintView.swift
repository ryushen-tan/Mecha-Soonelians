import SwiftUI

/// The hiding controls over the AR view: a + in the middle, and one big button that picks up the
/// color under the + from the real room, or sprays while held when the + is on the body. The pose
/// button cycles poses (hold it for the pose wheel). The chameleon sticks to a wall or lies on the
/// floor; it can be dragged, pinched and twisted, slid along its surface with the joystick, and spun
/// with a slider.
struct SprayPaintView: View {
    @ObservedObject var painter: SprayPainter
    let timeLeft: String
    var onHide: () -> Void
    var onCancel: () -> Void

    /// Whether the current press is spraying (it started on the body) rather than picking.
    @State private var pressing = false
    @State private var showsWheel = false
    @State private var wheelPage = 0
    @State private var highlightedPose: String?

    private var sprayMode: Bool { painter.isSpraying || painter.aimingAtBody }

    var body: some View {
        ZStack {
            crosshair
            VStack(spacing: 0) {
                topBar
                if painter.debug, !painter.debugText.isEmpty {
                    Text(painter.debugText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Debug info")
                }
                Spacer()
                moveControls
                bottomPanel
            }
            if showsWheel { poseWheel }
        }
    }

    private var poseWheel: some View {
        ZStack {
            RallyStyle.ink.opacity(0.22).ignoresSafeArea()
                .onTapGesture { showsWheel = false }
                .accessibilityLabel("Close pose wheel")
                .accessibilityAddTraits(.isButton)
            PoseWheel(page: $wheelPage, highlighted: $highlightedPose, current: painter.poseID, pages: painter.posePages) { id in
                painter.setPose(id: id)
                showsWheel = false
            }
            .frame(maxWidth: 340)
            .padding(24)
        }
    }

    private var hint: String {
        if !painter.isReady { return "Putting your chameleon in the room…" }
        if let notice = painter.notice { return notice }
        if painter.isSelected { return "Drag it onto a wall or the floor. Pinch to resize, twist to spin. Tap it to let go." }
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
            roundButton("ladybug", label: painter.debug ? "Hide debug info" : "Show debug info") { painter.debug.toggle() }
            roundButton("arrow.uturn.backward", label: "Undo") { painter.undo() }
                .disabled(!painter.canUndo)
                .opacity(painter.canUndo ? 1 : 0.4)
            VStack(spacing: 2) {
                Image(systemName: painter.poseIcon).font(.system(size: 20, weight: .semibold))
                Text(painter.poseName).font(RallyStyle.font(10, .semibold)).lineLimit(1)
            }
            .frame(width: 64, height: 50)
            .background(RallyStyle.lime, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { painter.nextPose() }
            .onLongPressGesture(minimumDuration: 0.35) {
                guard painter.isReady else { return }
                highlightedPose = nil
                showsWheel = true
            }
            .accessibilityElement()
            .accessibilityLabel("Pose: \(painter.poseName)")
            .accessibilityHint("Switches to the next pose. Hold for every pose.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { painter.nextPose() }
            .accessibilityAction(named: "All poses") { showsWheel = true }
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

    /// The joystick slides the chameleon up, down, left and right along its wall or floor; the slider spins it.
    private var moveControls: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Joystick { painter.joystick = $0 }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    placeButton("Wall", systemImage: "rectangle.portrait", selected: painter.onWall) { painter.stickToWall() }
                    placeButton("Floor", systemImage: "square.bottomhalf.filled", selected: !painter.onWall) { painter.stickToFloor() }
                }
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)
                    Slider(value: Binding(get: { painter.turn }, set: { painter.setTurn($0) }), in: -180...180)
                        .tint(RallyStyle.ink)
                        .accessibilityLabel("Spin")
                        .accessibilityValue("\(Int(painter.turn)) degrees")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RallyStyle.surface.opacity(0.92), in: Capsule())
                .overlay(Capsule().stroke(RallyStyle.ink, lineWidth: 2))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .opacity(painter.isReady ? 1 : 0.5)
        .disabled(!painter.isReady)
    }

    private func placeButton(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(RallyStyle.font(14, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(selected ? RallyStyle.lime : RallyStyle.surface.opacity(0.92), in: Capsule())
                .overlay(Capsule().stroke(RallyStyle.ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stick to \(title.lowercased())")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
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
        .accessibilityLabel("Slide your chameleon")
        .accessibilityAdjustableAction { direction in
            onChange(SIMD2(0, direction == .increment ? 1 : -1))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                onChange(.zero)
            }
        }
    }
}
