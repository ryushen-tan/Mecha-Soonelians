import SwiftUI

private enum CharacterEditorMode { case arrange, paint }
private enum CharacterEditorPanel: String, Identifiable {
    case tools, game
    var id: String { rawValue }
}

struct CharacterStudioView: View {
    @ObservedObject var model: Character3DModel
    @Environment(\.gameConnection) private var connection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var game = CharacterGameModel()
    @State private var mode = CharacterEditorMode.arrange
    @State private var panel: CharacterEditorPanel?
    @State private var confirmsClose = false
    @State private var closesAfterSave = false
    @State private var wheelPage = 0
    @State private var highlightedPose: String?
    private var hunting: Bool { game.snapshot?.phase == "hunting" && ["hunter", "dual"].contains(game.snapshot?.role ?? "") }
    private var roundLocked: Bool { game.snapshot?.phase == "hunting" }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CharacterWebView(model: model)
                    .accessibilityIdentifier("characterCanvas")
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    sceneToolbar
                    if model.saved {
                        Label("Character, paint and pose saved", systemImage: "checkmark.circle.fill")
                            .font(RallyStyle.font(12, .semibold)).padding(10)
                            .background(RallyStyle.paper.opacity(0.94), in: Capsule())
                    }
                    if let error = model.error {
                        ErrorNotice(message: error).padding(12).background(RallyStyle.paper, in: RoundedRectangle(cornerRadius: 16))
                    } else if let warning = model.warning {
                        Label(warning, systemImage: "info.circle")
                            .font(RallyStyle.font(12)).lineLimit(4).padding(12)
                            .background(RallyStyle.paper.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
                            .allowsHitTesting(false)
                    }
                    Spacer()
                    if !model.showsWheel && panel == nil { sceneControls }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 18)
                if model.showsWheel && mode == .arrange && !roundLocked {
                    RallyStyle.ink.opacity(0.22).ignoresSafeArea().onTapGesture { model.showsWheel = false }
                    VStack(spacing: 18) {
                        Text("Choose a pose").font(RallyStyle.font(17, .bold))
                            .padding(.horizontal, 18).padding(.vertical, 10).background(RallyStyle.paper, in: Capsule())
                        PoseWheel(page: $wheelPage, highlighted: $highlightedPose, current: model.editing.preset) { model.selectPose($0) }
                            .frame(width: min(340, geometry.size.width - 32), height: min(340, geometry.size.width - 32))
                        Text("Tap a pose · tap outside to close").font(RallyStyle.font(12, .semibold))
                            .padding(10).background(RallyStyle.paper, in: Capsule())
                    }
                }
                if !model.viewerLoaded { ProgressView("Loading character…").padding(16).background(RallyStyle.paper, in: Capsule()) }
            }
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .foregroundStyle(RallyStyle.ink).tint(RallyStyle.ink)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(item: $panel) { value in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if value == .game { CharacterPlayPanel(model: model, game: game) }
                        else if mode == .arrange { placementControls; poseControls }
                        else { paintControls }
                        if let warning = model.warning { Text(warning).font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted) }
                    }.padding(20)
                }
                .background(RallyStyle.paper)
                .navigationTitle(value == .game ? "Game controls" : mode == .arrange ? "Position & pose" : "Paint tools")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { panel = nil }.accessibilityIdentifier("dismissEditorPanelButton") } }
            }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .confirmationDialog("Save your disguise before leaving?", isPresented: $confirmsClose, titleVisibility: .visible) {
            Button("Save and close") { closesAfterSave = true; model.export() }
            Button("Keep editing") { confirmsClose = false }.accessibilityIdentifier("keepEditingButton")
            Button("Close without saving", role: .destructive) { dismiss() }
        } message: { Text("Unsaved paint, pose and position changes will be lost.") }
        .onChange(of: model.saved) { _, saved in if saved && closesAfterSave { dismiss() } }
        .onAppear {
            mode = model.editing.placementLocked == true ? .paint : .arrange
            model.editing.room = true
            if mode == .arrange { model.unlockPlacement() }
            game.connect(connection, editor: model)
        }
        .onDisappear { model.command("endTransform"); game.stop() }
        .onChange(of: scenePhase) { _, value in if value != .active { model.command("endTransform") } }
        .onChange(of: connection) { _, value in game.connect(value, editor: model) }
        .onChange(of: model.error) { _, value in if value != nil { closesAfterSave = false; game.exportFailed() } }
        .onChange(of: game.snapshot?.phase) { _, value in
            if value == "hunting" {
                panel = nil; model.editing.room = true; model.showsWheel = false
                model.editing.tool = hunting ? "tag" : "orbit"
            }
        }
        .onChange(of: game.snapshot?.role) { _, value in
            if game.snapshot?.phase == "hunting", ["hunter", "dual"].contains(value ?? "") {
                panel = nil; model.editing.room = true; model.editing.tool = "tag"
            }
        }
        .onChange(of: mode) { _, value in
            guard !roundLocked else { return }
            panel = nil
            if value == .paint {
                model.lockPlacement()
            } else {
                model.unlockPlacement()
            }
        }
        .onChange(of: model.editing.tool) { _, value in
            if roundLocked {
                if !["orbit", "tag"].contains(value) { model.editing.tool = hunting ? "tag" : "orbit" }
            } else {
                if ["paint", "sample", "erase"].contains(value) { mode = .paint }
                if value == "attach" { mode = .arrange }
            }
        }
        .onChange(of: model.editing) { _, _ in model.saved = false }
        .onChange(of: model.viewerLoaded) { _, loaded in
            if loaded {
                if mode == .paint { model.lockPlacement() }
                else { model.command("roomView") }
            }
        }
        .onChange(of: model.yaw) { _, _ in model.saved = false }
        .onChange(of: model.angles) { _, _ in model.saved = false }
        .onChange(of: model.showsWheel) { _, value in if (roundLocked || mode == .paint) && value { model.showsWheel = false } }
    }

    private var sceneToolbar: some View {
        HStack(spacing: 10) {
            Button { if model.saved || roundLocked { dismiss() } else { confirmsClose = true } } label: { hudIcon("xmark") }
                .accessibilityLabel("Close editor").accessibilityIdentifier("close3DEditorButton")
            Spacer(minLength: 0)
            Menu {
                Button("Position & pose", systemImage: "move.3d") { mode = .arrange }.accessibilityIdentifier("editorPositionMode")
                Button("Paint", systemImage: "paintbrush.pointed") { mode = .paint }.accessibilityIdentifier("editorPaintMode")
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Text(roundLocked ? "\(game.snapshot?.remaining ?? 0)s · Hunt" : mode == .arrange ? "Position & pose" : "Paint · locked")
                            .font(RallyStyle.font(12, .bold))
                        if !roundLocked { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                    }
                    Text(model.roomName).font(RallyStyle.font(10)).foregroundStyle(RallyStyle.muted)
                }.padding(.horizontal, 14).padding(.vertical, 8).background(RallyStyle.paper.opacity(0.94), in: Capsule())
            }.disabled(roundLocked).accessibilityIdentifier("editorModeButton")
            Spacer(minLength: 0)
            if !roundLocked {
                Button { if mode == .arrange { mode = .paint } else { model.export() } } label: {
                    hudIcon(model.exporting ? "hourglass" : mode == .arrange ? "lock.fill" : "checkmark", color: RallyStyle.lime)
                }
                .disabled(!model.viewerLoaded || model.exporting)
                .accessibilityLabel(mode == .arrange ? "Lock position and paint" : "Save disguise")
                .accessibilityIdentifier(mode == .arrange ? "lockPlacementButton" : "save3DCharacterButton")
            }
            Menu {
                Button("More tools", systemImage: "slider.horizontal.3") { model.showsWheel = false; panel = .tools }
                    .disabled(roundLocked).accessibilityIdentifier("editorToolsButton")
                Button("Frame character", systemImage: "viewfinder") { if mode == .paint { model.preparePainting() } else { model.command("roomView") } }
                    .accessibilityIdentifier("paintWallViewButton")
                Button("Game controls", systemImage: "gamecontroller") { model.showsWheel = false; panel = .game }
                if let asset = model.asset, FileManager.default.fileExists(atPath: asset.directory.appendingPathComponent("character.glb").path) {
                    ShareLink(item: asset.directory.appendingPathComponent("character.glb")) { Label("Share saved", systemImage: "square.and.arrow.up") }
                }
            } label: { hudIcon("ellipsis") }.accessibilityLabel("Editor options").accessibilityIdentifier("editorOptionsButton")
        }.buttonStyle(.plain)
    }

    private var sceneControls: some View {
        HStack(alignment: .bottom) {
            if mode == .arrange && !roundLocked && model.viewerLoaded && !model.editing.frozen {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.objectSelected ? transformHint : "Tap your person to select and drag")
                        .font(RallyStyle.font(10, .semibold)).padding(8)
                        .background(RallyStyle.paper.opacity(0.94), in: Capsule())
                        .accessibilityIdentifier("objectTransformHint")
                    HStack(spacing: 4) {
                        transformButton("translate", title: "Move", icon: "move.3d")
                        transformButton("rotate", title: "Rotate", icon: "rotate.3d")
                        transformButton("scale", title: "Size", icon: "arrow.up.left.and.arrow.down.right")
                    }.padding(5).background(RallyStyle.paper.opacity(0.94), in: Capsule())
                }
            } else if mode == .paint && !roundLocked {
                HStack(spacing: 10) {
                    Button { panel = .tools } label: {
                        Circle().fill(Color.paintHex(model.editing.color)).frame(width: 36, height: 36)
                            .overlay(Circle().stroke(RallyStyle.paper, lineWidth: 3))
                    }.accessibilityLabel("Paint colors").accessibilityIdentifier("paintColorsButton")
                    Menu {
                        Button("Brush", systemImage: "paintbrush.pointed") { model.editing.tool = "paint" }
                        Button("Sample", systemImage: "eyedropper") { model.editing.tool = "sample" }
                        Button("Erase", systemImage: "eraser") { model.editing.tool = "erase" }
                        Button("Orbit", systemImage: "rotate.3d") { model.editing.tool = "orbit" }
                    } label: { Image(systemName: model.editing.tool == "sample" ? "eyedropper" : model.editing.tool == "erase" ? "eraser" : model.editing.tool == "orbit" ? "rotate.3d" : "paintbrush.pointed").frame(width: 36, height: 44) }
                    .accessibilityLabel("Paint tool")
                    Button { model.command("undo") } label: { Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 44) }
                        .disabled(model.undoCount == 0).accessibilityLabel("Undo paint")
                    Button { model.command("redo") } label: { Image(systemName: "arrow.uturn.forward").frame(width: 32, height: 44) }
                        .disabled(model.redoCount == 0).accessibilityLabel("Redo paint")
                }.padding(.horizontal, 12).padding(.vertical, 4).background(RallyStyle.paper.opacity(0.94), in: Capsule())
            }
            Spacer()
            if mode == .arrange && !roundLocked && model.viewerLoaded {
                VStack(spacing: 20) {
                    Button { model.showsWheel.toggle() } label: {
                        VStack(spacing: 4) {
                            hudIcon("figure.arms.open", color: RallyStyle.lime)
                            Text("Pose").font(RallyStyle.font(11, .bold)).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RallyStyle.paper.opacity(0.94), in: Capsule())
                        }
                    }.disabled(!model.supportsHumanoid).accessibilityLabel("Pose").accessibilityIdentifier("poseWheelButton")
                }
            } else if roundLocked && game.snapshot?.role != "hunter" {
                Button { game.eject() } label: {
                    VStack(spacing: 4) {
                        hudIcon("arrow.up.forward", color: RallyStyle.coral)
                        Text(game.snapshot?.eject?.used == true ? "Used" : "Eject").font(RallyStyle.font(11, .bold))
                            .padding(5).background(RallyStyle.paper.opacity(0.94), in: Capsule())
                    }
                }.disabled(game.busy || game.snapshot?.eject?.available != true).accessibilityLabel("Emergency eject").accessibilityIdentifier("hudEmergencyEjectButton")
            }
        }.buttonStyle(.plain)
    }

    private var transformHint: String {
        switch model.editing.transformMode ?? "translate" {
        case "rotate": return "Drag the X / Y / Z rings to rotate"
        case "scale": return "Drag a size handle · or drag your person up/down"
        default: return "Drag your person or the arrows · pinch to zoom"
        }
    }

    private func transformButton(_ mode: String, title: String, icon: String) -> some View {
        Button {
            model.editing.tool = "orbit"
            model.editing.transformMode = mode
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(RallyStyle.font(10, .bold))
            }
            .frame(width: 48, height: 48)
            .background((model.editing.transformMode ?? "translate") == mode ? RallyStyle.lime : Color.clear, in: Capsule())
        }
        .accessibilityLabel("\(title) object")
        .accessibilityIdentifier("objectTransform_\(mode)")
    }

    private func hudIcon(_ name: String, color: Color = RallyStyle.paper.opacity(0.94)) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .semibold))
            .frame(width: 44, height: 44).background(color, in: Circle())
            .overlay(Circle().stroke(RallyStyle.ink.opacity(0.12)))
    }

    private var poseControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Advanced joints", isOn: $model.showsSkeleton).font(RallyStyle.font(12))
            if model.showsSkeleton && !model.bones.isEmpty {
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
                Button("Reset pose") { model.selectPose("original") }.font(RallyStyle.font(13, .semibold))
            }
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
            HStack {
                Label(model.roomName, systemImage: "square.split.bottomrightquarter").lineLimit(1)
                Spacer()
                Button { model.command("zoomOut") } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out")
                Button { model.command("zoomIn") } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in")
                Button("Frame body") { model.preparePainting() }
                    .accessibilityIdentifier("paintFrameBodyButton")
            }.font(RallyStyle.font(12, .semibold))
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
            Text("Pinch to zoom closer for finer detail. Two fingers pan without painting. Sample the background to match its color. Orbit changes only your view; switch to Position & pose to move your body.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
        }
        .disabled(model.editing.frozen)
    }

    private var placementControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.roomName, systemImage: "square.split.bottomrightquarter").font(RallyStyle.font(12, .semibold))
            HStack {
                Button { model.editing.room = true; model.editing.tool = "attach" } label: { Label("Attach to surface", systemImage: "hand.point.up.left") }
                Button("To floor") { model.command("detach") }
                Button("Against wall") { model.preparePainting(againstWall: true); model.editing.tool = "orbit" }
            }.font(RallyStyle.font(13, .semibold))
            editorSlider("Body size", value: $model.editing.scale, range: 0.15...1.5)
            editorSlider("Turn", value: $model.yaw, range: -180...180)
            Text(model.editing.tool == "attach" ? "Tap a floor, wall or object. Your whole body must fit without overlapping furniture." : "Tap your person to select it, then drag to move. Use Rotate for X/Y/Z rotation rings and Size for uniform resizing. Surfaces stay solid. Drag the background to orbit; pinch to zoom.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            DisclosureGroup("Body form & clones") {
                VStack(alignment: .leading, spacing: 14) {
                    if model.supportsHumanoid {
                        Picker("Body form", selection: Binding(get: { model.editing.form ?? "person" }, set: { model.editing.form = $0 })) {
                            Text("Your mesh").tag("person"); Text("Rounded").tag("rounded"); Text("Blocky").tag("blocky")
                        }.pickerStyle(.segmented)
                    }
                    HStack {
                        Button { model.command("clone") } label: { Label("Clone \(model.cloneCount)/2", systemImage: "person.2") }
                            .disabled(model.cloneCount >= 2)
                        Button("Clear clones") { model.command("clearClones") }.disabled(model.cloneCount == 0)
                    }.font(RallyStyle.font(13, .semibold))
                    Text("A clone keeps the current paint and pose. In a round, finding any clone also finds its owner.")
                        .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
            }.font(RallyStyle.font(13, .semibold))
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

}
