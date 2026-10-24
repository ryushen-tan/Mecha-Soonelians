import SwiftUI

private enum CharacterToolTab: String, CaseIterable { case pose = "Pose", paint = "Paint", place = "Place", play = "Play" }

struct CharacterStudioView: View {
    @ObservedObject var model: Character3DModel
    @Environment(\.gameConnection) private var connection
    @StateObject private var game = CharacterGameModel()
    @State private var tab = CharacterToolTab.pose
    @State private var wheelPage = 0
    @State private var highlightedPose: String?
    @State private var canvasFrame = CGRect.zero
    private var hunting: Bool { game.snapshot?.phase == "hunting" && ["hunter", "dual"].contains(game.snapshot?.role ?? "") }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                GeometryReader { canvas in
                    ZStack {
                        CharacterWebView(model: model)
                            .accessibilityIdentifier("characterCanvas")
                        if model.showsWheel {
                            RallyStyle.ink.opacity(0.08).allowsHitTesting(false)
                            PoseWheel(page: $wheelPage, highlighted: $highlightedPose, current: model.editing.preset) { model.selectPose($0) }
                                .frame(width: max(1, min(310, canvas.size.width - 12, canvas.size.height - 12)), height: max(1, min(310, canvas.size.width - 12, canvas.size.height - 12)))
                        }
                        if !model.viewerLoaded { ProgressView("Loading character…").padding(16).background(RallyStyle.paper, in: Capsule()) }
                    }
                    .onAppear { canvasFrame = canvas.frame(in: .global) }
                    .onChange(of: canvas.size) { _, _ in canvasFrame = canvas.frame(in: .global) }
                }
                .frame(maxHeight: .infinity).clipped()
                HStack(spacing: 12) {
                    Button { model.editing.tool = "orbit"; model.showsWheel = false } label: { Label("Orbit", systemImage: "rotate.3d") }
                        .accessibilityIdentifier("orbitCharacterButton")
                    Button { model.command("inspect") } label: { Image(systemName: "viewfinder") }.accessibilityLabel("Frame character")
                    Spacer()
                    Button {
                        model.editing.frozen.toggle()
                        if model.editing.frozen { model.editing.tool = "orbit"; model.showsWheel = false }
                    } label: { Label(model.editing.frozen ? "Unfreeze" : "Freeze", systemImage: model.editing.frozen ? "lock.fill" : "lock.open") }
                }
                .font(RallyStyle.font(12, .semibold)).padding(.horizontal, 16).padding(.vertical, 6)
                .disabled(hunting)
                Picker("Character tools", selection: $tab) {
                    ForEach(CharacterToolTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12).disabled(hunting)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch tab {
                        case .pose: poseControls
                        case .paint: paintControls
                        case .place: placementControls
                        case .play: CharacterPlayPanel(model: model, game: game)
                        }
                        if let warning = model.warning { Text(warning).font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted) }
                        if let error = model.error { ErrorNotice(message: error) }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                }
                .frame(height: min(260, max(180, geometry.size.height * 0.34)))
                VStack(spacing: 7) {
                    HStack {
                        if model.saved { Label("Character, paint and pose saved", systemImage: "checkmark.circle.fill").foregroundStyle(RallyStyle.success) }
                        Spacer()
                        if let asset = model.asset, FileManager.default.fileExists(atPath: asset.directory.appendingPathComponent("character.glb").path) {
                            ShareLink(item: asset.directory.appendingPathComponent("character.glb")) { Label("Share saved", systemImage: "square.and.arrow.up") }
                        }
                    }.font(RallyStyle.font(11, .semibold))
                    Button { model.export() } label: { ActionLabel(text: "Save character", busy: model.exporting) }
                        .buttonStyle(PushButtonStyle()).disabled(!model.viewerLoaded || model.exporting)
                        .accessibilityIdentifier("save3DCharacterButton")
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .foregroundStyle(RallyStyle.ink).tint(RallyStyle.ink)
        .onAppear { game.connect(connection, editor: model) }
        .onDisappear { game.stop() }
        .onChange(of: connection) { _, value in game.connect(value, editor: model) }
        .onChange(of: model.error) { _, value in if value != nil { game.exportFailed() } }
        .onChange(of: game.snapshot?.phase) { _, value in
            if value == "hunting", ["hunter", "dual"].contains(game.snapshot?.role ?? "") {
                tab = .play; model.editing.room = true; model.editing.tool = "tag"
            }
        }
        .onChange(of: game.snapshot?.role) { _, value in
            if game.snapshot?.phase == "hunting", ["hunter", "dual"].contains(value ?? "") {
                tab = .play; model.editing.room = true; model.editing.tool = "tag"
            }
        }
        .onChange(of: tab) { _, value in
            if game.snapshot?.phase == "hunting", ["hunter", "dual"].contains(game.snapshot?.role ?? "") {
                tab = .play; model.editing.tool = "tag"; return
            }
            model.showsWheel = false
            model.editing.tool = value == .paint && !model.editing.frozen ? "paint" : "orbit"
        }
        .onChange(of: model.editing.tool) { _, value in
            if ["paint", "sample", "erase"].contains(value) { tab = .paint }
            if value == "attach" { tab = .place }
            if value == "tag" { tab = .play }
        }
        .onChange(of: model.editing) { _, _ in model.saved = false }
        .onChange(of: model.yaw) { _, _ in model.saved = false }
        .onChange(of: model.angles) { _, _ in model.saved = false }
        .onChange(of: model.showsWheel) { _, value in if hunting && value { model.showsWheel = false } }
    }

    private var poseControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { model.showsWheel.toggle() } label: {
                    Label("Pose wheel", systemImage: "circle.hexagongrid.fill").font(RallyStyle.font(16, .bold))
                }
                .accessibilityIdentifier("poseWheelButton")
                .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        model.showsWheel = true
                        let side = max(1, min(310, canvasFrame.width - 12, canvasFrame.height - 12))
                        highlightedPose = PoseWheel.choice(at: CGPoint(x: value.location.x - canvasFrame.midX + side / 2,
                            y: value.location.y - canvasFrame.midY + side / 2), side: side, page: wheelPage)
                    }
                    .onEnded { _ in if let highlightedPose { model.selectPose(highlightedPose) }; highlightedPose = nil })
                .disabled(!model.supportsHumanoid || model.editing.frozen)
                Spacer()
                Toggle("Joints", isOn: $model.showsSkeleton).font(RallyStyle.font(12)).fixedSize()
            }
            Text(model.supportsHumanoid ? "Hold, drag toward a pose, then release. Tap the center of the wheel for more poses." : "This model has no humanoid rig. Available joints can still be edited below.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            if !model.bones.isEmpty {
                Picker("Joint", selection: $model.selectedBone) {
                    ForEach(model.bones) { bone in Text(bone.displayName).tag(bone.id) }
                }.pickerStyle(.menu)
                Picker("Rotation axis", selection: $model.selectedAxis) {
                    Text("Bend").tag(0); Text("Twist").tag(1); Text("Swing").tag(2)
                }.pickerStyle(.segmented)
                HStack {
                    Slider(value: Binding(get: { min(model.angleRange.upperBound, max(model.angleRange.lowerBound, model.currentAngle)) }, set: { model.setAngle($0) }), in: model.angleRange, step: 1)
                        .accessibilityLabel("3D joint angle")
                    Text("\(Int(model.currentAngle))°").font(RallyStyle.font(13)).monospacedDigit().frame(width: 40)
                }
            }
            Button("Reset pose") { model.selectPose("original") }.font(RallyStyle.font(13, .semibold))
        }
        .disabled(model.editing.frozen)
    }

    private var paintControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Paint your disguise").font(RallyStyle.font(18, .bold))
                Spacer()
                Button { model.command("undo") } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(model.undoCount == 0).accessibilityLabel("Undo paint")
                Button { model.command("redo") } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(model.redoCount == 0).accessibilityLabel("Redo paint")
            }
            Picker("Paint tool", selection: $model.editing.tool) {
                Text("Brush").tag("paint"); Text("Sample").tag("sample"); Text("Erase").tag("erase"); Text("Orbit").tag("orbit")
            }.pickerStyle(.segmented)
            PaintColorWheel(hex: $model.editing.color)
            editorSlider("Brush size", value: $model.editing.brush, range: 0.005...0.15)
            editorSlider("Opacity", value: $model.editing.opacity, range: 0.1...1)
            HStack {
                Button("Fill") { model.command("fill") }
                Button("White base") { model.command("white") }
                Button("Original colors") { model.command("originalColor") }
            }.font(RallyStyle.font(12, .semibold))
            editorSlider("Metallic", value: $model.editing.metallic, range: 0...1)
            editorSlider("Roughness", value: $model.editing.roughness, range: 0.05...1)
            Toggle("Cast shadow", isOn: $model.editing.shadows).font(RallyStyle.font(14))
            Toggle("See own body through walls", isOn: Binding(get: { model.editing.xray ?? false }, set: { model.editing.xray = $0 })).font(RallyStyle.font(14))
            Text("Paint directly on the body. Sample a room surface to copy its color. Switch to Orbit to inspect the other side.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
        }
        .disabled(model.editing.frozen)
    }

    private var placementControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(model.roomName).font(RallyStyle.font(18, .bold)); Spacer(); Toggle("Room", isOn: $model.editing.room).labelsHidden() }
            HStack {
                Button { model.editing.room = true; model.editing.tool = "attach" } label: { Label("Attach to surface", systemImage: "hand.point.up.left") }
                Button("Detach") { model.command("detach") }
            }.font(RallyStyle.font(13, .semibold))
            Text(model.editing.tool == "attach" ? "Tap a floor, wall or object in the room." : "Turn on the room, attach to a surface, then fine-tune your position.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            HStack {
                Button { nudge(0, -0.1) } label: { Image(systemName: "arrow.left") }.accessibilityLabel("Move left")
                Button { nudge(0, 0.1) } label: { Image(systemName: "arrow.right") }.accessibilityLabel("Move right")
                Button { nudge(2, -0.1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move forward")
                Button { nudge(2, 0.1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move backward")
                Button { nudge(1, 0.1) } label: { Image(systemName: "arrow.up.to.line") }.accessibilityLabel("Move higher")
                Button { nudge(1, -0.1) } label: { Image(systemName: "arrow.down.to.line") }.accessibilityLabel("Move lower")
            }
            editorSlider("Body size", value: $model.editing.scale, range: 0.5...1.5)
            if model.supportsHumanoid {
                Picker("Body form", selection: Binding(get: { model.editing.form ?? "person" }, set: { model.editing.form = $0 })) {
                    Text("Your mesh").tag("person"); Text("Rounded").tag("rounded"); Text("Blocky").tag("blocky")
                }.pickerStyle(.segmented)
            }
            editorSlider("Turn", value: $model.yaw, range: -180...180)
            HStack {
                Button { model.command("clone") } label: { Label("Clone \(model.cloneCount)/2", systemImage: "person.2") }
                    .disabled(model.cloneCount >= 2)
                Button("Clear clones") { model.command("clearClones") }.disabled(model.cloneCount == 0)
            }.font(RallyStyle.font(13, .semibold))
            Text("A clone keeps the current paint and pose. In a round, finding any clone also finds its owner.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
        }
        .disabled(model.editing.frozen)
    }

    private func editorSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(RallyStyle.font(12)).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title)
            Text(String(format: "%.2f", value.wrappedValue)).font(RallyStyle.font(11)).monospacedDigit().frame(width: 38)
        }
    }

    private func nudge(_ axis: Int, _ distance: Double) {
        model.editing.position[axis] = min(50, max(-50, model.editing.position[axis] + distance))
    }
}
