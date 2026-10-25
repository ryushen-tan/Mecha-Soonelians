// Hallmark · native AR controls · design-system: design.md
// Pre-emit critique: P5 H4 E4 S5 R5 V4. Fixed controls keep the camera view central.
import SwiftUI

/// Persistent movement, pose, color picking and spraying controls over the live AR view.
struct SprayPaintView: View {
    @ObservedObject var painter: SprayPainter
    let timeLeft: String
    var onHide: () -> Void
    var onCancel: () -> Void

    #if DEBUG
    var previewPoses = false
    #endif

    @State private var pressing = false
    @State private var showsPoses = false

    @Environment(\.scenePhase) private var scenePhase

    private var sprayMode: Bool { painter.isSpraying || (!pressing && painter.aimingAtBody) }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 650
            ZStack {
                crosshair
                VStack(spacing: 0) {
                    topBar(compact: compact)
                    Spacer(minLength: 0)
                    bottomPanel(compact: compact)
                }
                .allowsHitTesting(!showsPoses)
                .accessibilityHidden(showsPoses)
                if showsPoses { posePicker }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(JellyStyle.ink)
        .onAppear {
            #if DEBUG
            if previewPoses { openPoses() }
            #endif
        }
        .onDisappear { stopMovingAndSpraying() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopMovingAndSpraying() }
        }
    }

    private var posePicker: some View {
        ZStack {
            JellyStyle.ink.opacity(0.22).ignoresSafeArea()
                .onTapGesture { showsPoses = false }
                .accessibilityLabel("Close poses")
                .accessibilityAddTraits(.isButton)
            VStack(spacing: 12) {
                HStack {
                    Text("All \(painter.poseChoices.count) poses").font(JellyStyle.body(20))
                    Spacer()
                    roundButton("xmark", label: "Close poses") { showsPoses = false }
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(painter.poseChoices) { choice in
                            let selected = painter.poseID == choice.id
                            let available = painter.canSelectPose(id: choice.id)
                            Button {
                                guard painter.canSelectPose(id: choice.id) else { return }
                                painter.setPose(id: choice.id)
                                showsPoses = false
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: choice.icon).font(.system(size: 24))
                                    Text(choice.name).font(JellyStyle.body(12))
                                        .lineLimit(1).minimumScaleFactor(0.75)
                                    Text(selected ? "Selected" : available ? "" : "Needs space")
                                        .font(JellyStyle.body(10)).lineLimit(1).minimumScaleFactor(0.75)
                                }
                                .frame(maxWidth: .infinity, minHeight: 76)
                                .foregroundStyle(selected ? JellyStyle.paper : available ? JellyStyle.ink : JellyStyle.muted)
                                .background(selected ? JellyStyle.blue : JellyStyle.field, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(JellyStyle.ink, lineWidth: selected ? 2 : 1))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(!available)
                            .accessibilityLabel("Pose: \(choice.name)")
                            .accessibilityValue(selected ? "Selected" : available ? "Available" : "Needs more space")
                            .accessibilityIdentifier("poseChoice_\(choice.id)")
                        }
                    }
                }
                .frame(maxHeight: 420)
                Text("Some poses need more space. Move your figure away from walls or furniture to use them.")
                    .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(JellyStyle.ink, lineWidth: 2))
            .frame(maxWidth: 400)
            .padding(16)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var hint: String {
        if !painter.isReady { return "Putting your chameleon in the room…" }
        if let notice = painter.notice { return notice }
        if painter.isSelected { return "Drag to move. Pinch to resize. Tap to let go." }
        if !painter.hasPickedColor { return "Aim + at the room, then tap Pick." }
        if painter.isSpraying { return "Keep + on your figure while spraying." }
        return "Aim + at your figure. Hold Spray to paint."
    }

    private func topBar(compact: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    JellyEyebrow(text: "SPRAY PAINT · \(timeLeft)")
                    Text(hint)
                        .font(JellyStyle.body(13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                roundButton("arrow.uturn.backward", label: "Undo") { painter.undo() }
                    .disabled(!painter.canUndo)
                    .opacity(painter.canUndo ? 1 : 0.4)
            }
            if compact { sliders }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(JellyStyle.ink, lineWidth: 2))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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

    private func bottomPanel(compact: Bool) -> some View {
        VStack(spacing: 10) {
            if let error = painter.error { JellyNotice(message: error) }
            HStack(spacing: 12) {
                Joystick { painter.joystick = $0 }
                VStack(spacing: 8) {
                    poseButton
                    paintButton
                }
            }
            .disabled(!painter.isReady)
            .opacity(painter.isReady ? 1 : 0.5)
            if !compact { sliders }
            HStack {
                Button("Cancel", action: onCancel)
                    .font(JellyStyle.body(14))
                    .frame(minWidth: 60, minHeight: 44)
                Spacer()
                Button {
                    stopMovingAndSpraying()
                    onHide()
                } label: {
                    HStack(spacing: 16) {
                        Text("Hide here")
                        Image(systemName: "arrow.right")
                    }
                }
                    .buttonStyle(JellyButtonStyle(kind: .dark))
                    .disabled(!painter.isReady)
            }
        }
        .padding(12)
        .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(JellyStyle.ink, lineWidth: 2))
        .frame(maxWidth: 480)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var sliders: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Rotation").frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { painter.turn }, set: { painter.setTurn($0) }), in: -180...180)
                    .accessibilityLabel("Rotation")
                    .accessibilityValue("\(Int(painter.turn)) degrees")
                Text("\(Int(painter.turn))°").monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).frame(width: 42, alignment: .trailing)
            }
            .frame(minHeight: 44)
            HStack(spacing: 8) {
                Text("Spray size").frame(width: 70, alignment: .leading)
                Slider(value: $painter.spread, in: 0...1)
                    .accessibilityLabel("Spray size")
                    .accessibilityValue("\(Int(painter.spread * 100)) percent")
                Text("\(Int(painter.spread * 100))%").monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).frame(width: 42, alignment: .trailing)
            }
            .frame(minHeight: 44)
        }
        .font(JellyStyle.body(12))
        .tint(JellyStyle.blue)
        .disabled(!painter.isReady)
    }

    private var poseButton: some View {
        HStack(spacing: 6) {
            Image(systemName: painter.poseIcon)
            Text("Pose · \(painter.poseName)").lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 14, weight: .bold))
        }
        .font(JellyStyle.body(13))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(JellyStyle.field, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(JellyStyle.ink, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { openPoses() }
        .onLongPressGesture(minimumDuration: 0.35) { openPoses() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pose: \(painter.poseName)")
        .accessibilityHint("Opens all \(painter.poseChoices.count) poses. Poses that need more space are marked.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openPoses() }
        .accessibilityAction(named: "Next available pose") { if painter.isReady { painter.nextPose() } }
    }

    private func openPoses() {
        guard painter.isReady else { return }
        stopMovingAndSpraying()
        showsPoses = true
    }

    private func toolLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
            Text(title).font(JellyStyle.body(14)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .contentShape(Rectangle())
    }

    private var paintButton: some View {
        toolLabel(painter.isSpraying ? "Spraying…" : sprayMode ? "Hold to spray" : "Pick color",
                  icon: sprayMode ? "paintbrush.pointed.fill" : "eyedropper.halffull")
        .foregroundStyle(sprayMode ? JellyStyle.paper : JellyStyle.ink)
        .background(painter.isSpraying ? JellyStyle.ink : sprayMode ? JellyStyle.blue : JellyStyle.paleBlue, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(JellyStyle.ink, lineWidth: 2))
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
        .accessibilityValue(painter.isSpraying ? "Spraying" : "Not spraying")
        .accessibilityHint(sprayMode ? "Hold to spray your figure where the plus points." : "Picks the room color under the plus. The ring shows your color.")
        .accessibilityIdentifier("sprayPickOrPaint")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard painter.isReady else { return }
            guard painter.aimingAtBody else {
                painter.pickColor()
                return
            }
            painter.isSpraying = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                painter.isSpraying = false
            }
        }
    }

    private func stopMovingAndSpraying() {
        pressing = false
        painter.isSpraying = false
        painter.joystick = .zero
    }

    private func roundButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(JellyStyle.field, in: Circle())
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
    private let radius: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(JellyStyle.field)
                .overlay(Circle().stroke(JellyStyle.ink, lineWidth: 2))
                .frame(width: radius * 2, height: radius * 2)
            Text("MOVE")
                .font(JellyStyle.body(9))
                .foregroundStyle(JellyStyle.muted)
                .offset(y: -radius + 15)
                .accessibilityHidden(true)
            Circle()
                .fill(JellyStyle.blue)
                .overlay(Circle().stroke(JellyStyle.ink, lineWidth: 2))
                .frame(width: 40, height: 40)
                .offset(knob)
        }
        .frame(width: radius * 2, height: radius * 2)
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
