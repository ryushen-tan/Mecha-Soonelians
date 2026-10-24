import PhotosUI
import SwiftUI

struct CaptureEditorView: View {
    @StateObject private var model = HumanEditorModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var tab = "Photo"
    @State private var showsSkeleton = true
    @State private var showsCamera = false
    @State private var isImporting = false
    @State private var characterInput: Data?
    @State private var shows3D = false
    private let accent = RallyStyle.lime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "CAPTURE YOUR CHARACTER")
                    Text("Find your people.")
                        .font(RallyStyle.font(34, .heavy)).tracking(-1)
                    Text(model.isSample ? "Human depth sample · TUM / Kinect" : (model.depth == nil ? "Your photo · no depth attached" : "Your capture · depth attached"))
                        .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
                Picker("Preview", selection: $tab) {
                    Text("Photo").tag("Photo")
                    Text("Cutout").tag("Cutout")
                    Text("Depth").tag("Depth")
                    Text("Pose").tag("Pose")
                }
                .pickerStyle(.segmented)
                Button {
                    characterInput = model.make3DCutout()
                    shows3D = characterInput != nil
                } label: {
                    Label("Make a 3D character", systemImage: "cube.transparent")
                        .font(RallyStyle.font(15, .bold)).frame(maxWidth: .infinity, minHeight: 48)
                }
                .background(RallyStyle.cyan, in: RoundedRectangle(cornerRadius: 14))
                .buttonStyle(.plain).rallyHover(cornerRadius: 14)
                .disabled(model.selectedHuman == nil || model.isProcessing || isImporting)
                .accessibilityIdentifier("make3DCharacterButton")
                ZStack {
                    RoundedRectangle(cornerRadius: 22).fill(RallyStyle.line.opacity(0.3))
                    if tab == "Pose" {
                        if model.canPose {
                            PoseCanvas(scene: model.poseScene, angles: model.angles, showsSkeleton: showsSkeleton)
                        } else {
                            ContentUnavailableView("No rig available", systemImage: "figure.stand", description: Text("Choose a person with visible joints to edit their pose."))
                        }
                    } else {
                        imageCanvas
                    }
                    if model.isProcessing || isImporting {
                        ProgressView("Finding people…")
                            .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(height: 290)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(RallyStyle.line))
                if !model.humans.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        personSelection
                        ScrollView(.horizontal, showsIndicators: false) { personSelection }
                    }
                }
                if tab == "Pose", model.canPose {
                    poseControls
                } else {
                    Text(model.status).font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                }
                HStack(spacing: 12) {
                    Button { showsCamera = true } label: {
                        Label("Scan person", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(RallyStyle.line))
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Import", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(RallyStyle.line))
                }
                .font(RallyStyle.font(14, .semibold))
                .buttonStyle(.plain).rallyHover(cornerRadius: 14)
                .disabled(model.isProcessing || isImporting)
                Text(tab == "Pose" ? "2D pose prototype: joints move pieces of the cutout. Hidden body surfaces cannot be reconstructed, so large changes may reveal gaps. Depth stays in the original capture pose." : "People are detected and cropped automatically. Use a clear full-body photo with arms slightly away from the body for better rigging.")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                if model.usesSampleAnalysis {
                    Label("Using saved Vision analysis for this sample because live analysis is unavailable here.", systemImage: "info.circle")
                        .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button {
                if model.canPose && tab != "Pose" { tab = "Pose" } else { model.save() }
            } label: {
                ActionLabel(text: model.canPose && tab != "Pose" ? "Edit pose" : "Save player")
            }
            .buttonStyle(PushButtonStyle())
            .accessibilityIdentifier("playerPrimaryAction")
            .disabled(model.selectedHuman == nil || model.isProcessing || isImporting)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: 540).frame(maxWidth: .infinity)
            .background(RallyStyle.paper)
        }
        .tint(RallyStyle.ink).foregroundStyle(RallyStyle.ink).preferredColorScheme(.light)
        .navigationTitle("Edit player").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $shows3D) {
            Character3DView(input: characterInput, attribution: model.isSample ? "TUM RGB-D fr3/walking_static. J. Sturm, N. Engelhard, F. Endres, W. Burgard, D. Cremers (IROS 2012). CC BY 4.0. https://cvg.cit.tum.de/data/datasets/rgbd-dataset" : nil, inputWarning: model.selectedHuman?.generationWarning)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sample") { Task { tab = "Photo"; await model.loadSample() } }.disabled(model.isProcessing || isImporting)
            }
        }
        .task { if model.photo == nil { await model.loadSample() } }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            isImporting = true
            defer { isImporting = false }
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                let capture = try await Task.detached { try CaptureImage.decode(data) }.value
                try Task.checkCancellation()
                tab = "Photo"
                await model.load(capture)
            } catch is CancellationError {
            } catch {
                model.message = "Couldn't import photo: \(error.localizedDescription)"
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            PersonCameraView { data in
                showsCamera = false
                Task {
                    do {
                        let capture = try await Task.detached { try CaptureImage.decode(data) }.value
                        tab = "Photo"
                        await model.load(capture)
                    } catch {
                        model.message = "Couldn't read capture: \(error.localizedDescription)"
                    }
                }
            }
        }
        .alert("Player editor", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var personSelection: some View {
        HStack {
            ForEach(Array(model.humans.enumerated()), id: \.element.id) { index, human in
                Button { model.select(human.id) } label: {
                    Label("Person \(index + 1)", systemImage: model.selectedID == human.id ? "checkmark.circle.fill" : "person")
                        .font(RallyStyle.font(12, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(model.selectedID == human.id ? accent : RallyStyle.surface, in: Capsule())
                }
            }
            Spacer()
            if let person = model.selectedHuman {
                Text("\(person.joints.count) joints").font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }
        }
        .buttonStyle(.plain)
    }

    private var imageCanvas: some View {
        GeometryReader { geometry in
            let image = tab == "Depth" ? model.depth?.preview : (tab == "Cutout" ? model.selectedHuman.map { UIImage(cgImage: $0.cutout) } : model.photo)
            if let image {
                let ratio = image.size.width / image.size.height
                let width = min(geometry.size.width, geometry.size.height * ratio)
                let height = width / ratio
                ZStack {
                    Image(uiImage: image).resizable()
                    if tab != "Cutout" {
                        ForEach(Array(model.humans.enumerated()), id: \.element.id) { index, human in
                            Button { model.select(human.id) } label: {
                                Rectangle().fill(.clear)
                                    .overlay(Rectangle().strokeBorder(model.selectedID == human.id ? accent : .white.opacity(0.5), lineWidth: 2))
                                    .overlay(alignment: .topLeading) {
                                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.black).padding(5).background(accent)
                                    }
                                    .contentShape(Rectangle())
                            }
                            .frame(width: human.bounds.width * width, height: human.bounds.height * height)
                            .position(x: human.bounds.midX * width, y: human.bounds.midY * height)
                            .accessibilityLabel("Select person \(index + 1)")
                        }
                    }
                }
                .frame(width: width, height: height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            } else {
                ContentUnavailableView(tab == "Depth" ? "No depth attached" : "No person selected", systemImage: "person.crop.rectangle",
                                       description: Text(tab == "Depth" ? "Use the sample, an original depth photo, or Scan person on a LiDAR device." : "Import or capture a photo to begin."))
            }
        }
    }

    private var poseControls: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Pose rig").font(RallyStyle.font(18, .bold))
                Spacer()
                Toggle("Joints", isOn: $showsSkeleton).font(.caption).fixedSize()
            }
            HStack {
                Button("Original") { model.angles = [:] }
                Button("Arms out") { model.preset(wave: false) }
                Button("Wave") { model.preset(wave: true) }
            }
            .buttonStyle(.bordered).font(.caption)
            Picker("Joint", selection: $model.selectedBone) {
                ForEach(model.bones) { bone in Text(bone.label).tag(bone.id) }
            }
            .pickerStyle(.menu)
            HStack {
                Button { adjustAngle(-10) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Rotate joint minus 10 degrees")
                Slider(value: Binding(get: { model.angles[model.selectedBone] ?? 0 }, set: { model.angles[model.selectedBone] = $0 }), in: -180...180, step: 1)
                    .accessibilityLabel("Joint rotation")
                Button { adjustAngle(10) } label: { Image(systemName: "plus.circle") }.accessibilityLabel("Rotate joint plus 10 degrees")
                Text("\(Int(model.angles[model.selectedBone] ?? 0))°").font(.caption.monospacedDigit()).frame(width: 38)
            }
        }
        .padding(18).background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line))
    }

    private func adjustAngle(_ amount: Double) {
        model.angles[model.selectedBone] = min(180, max(-180, (model.angles[model.selectedBone] ?? 0) + amount))
    }
}

#Preview {
    NavigationStack { CaptureEditorView() }
}
