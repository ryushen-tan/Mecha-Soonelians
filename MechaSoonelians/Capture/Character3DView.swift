import SwiftUI

struct Character3DView: View {
    let input: Data?
    let attribution: String?
    @StateObject private var model: Character3DModel
    @AppStorage("tripoServer") private var serverAddress = "http://localhost:3001"
    @State private var accessToken = ""
    @State private var confirmsUpload = false

    init(input: Data? = nil, attribution: String? = nil, asset: CharacterAsset? = nil) {
        self.input = input
        self.attribution = attribution
        _model = StateObject(wrappedValue: Character3DModel(asset: asset))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Eyebrow(text: "A CHARACTER FROM EVERY ANGLE")
                    Text("Meet your 3D self.").font(RallyStyle.font(32, .heavy)).tracking(-1)
                    if model.modelData != nil {
                        CharacterWebView(model: model)
                            .frame(height: min(350, max(220, geometry.size.height * 0.43)))
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityLabel("3D character. Drag to orbit and pinch to zoom.")
                        HStack(alignment: .top) {
                            Text(model.status).font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
                            Spacer()
                            Button {
                                model.yaw = model.yaw + 90 > 180 ? model.yaw - 270 : model.yaw + 90
                            } label: {
                                Label("Turn 90°", systemImage: "rotate.right")
                                    .font(RallyStyle.font(13, .semibold))
                            }
                            .disabled(!model.viewerLoaded).accessibilityIdentifier("turn3DCharacterButton")
                        }
                        controls
                    } else {
                        if let preview = input.flatMap(UIImage.init(data:)) ?? model.asset?.preview {
                            Image(uiImage: preview).resizable().scaledToFit().frame(height: 230).frame(maxWidth: .infinity)
                                .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                        }
                        if model.busy {
                            HStack { ProgressView(); Text(model.status).font(RallyStyle.font(16, .semibold)) }
                            Text("You can leave this page. Generation keeps running on your Mac; resume from Studio → 3D characters. Closing this screen does not cancel Tripo or refund credits.")
                                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                        } else {
                            connectionFields
                            Button {
                                if model.asset == nil { confirmsUpload = true } else { model.resume(token: accessToken) }
                            } label: {
                                ActionLabel(text: model.asset == nil ? "Generate + auto-rig" : "Resume generation")
                            }
                            .buttonStyle(PushButtonStyle()).disabled(input == nil && model.asset == nil)
                            .accessibilityIdentifier("generateCharacterButton")
                        }
                        Text("Uploads only this selected cutout to Tripo and uses your API credits. A standing full-body image with separated arms works best; seated or hidden limbs may not rig. Unseen surfaces are AI-generated, not measured LiDAR geometry.")
                            .font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
                    }
                    if let warning = model.warning { Text(warning).font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted) }
                    if let error = model.error { ErrorNotice(message: error) }
                    if let asset = model.asset, FileManager.default.fileExists(atPath: asset.directory.appendingPathComponent("character.glb").path) {
                        ShareLink(item: asset.directory.appendingPathComponent("character.glb")) {
                            Label("Share saved 3D mesh", systemImage: "square.and.arrow.up")
                        }.font(RallyStyle.font(14, .semibold))
                    }
                }
                .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .foregroundStyle(RallyStyle.ink).tint(RallyStyle.ink)
        .navigationTitle("3D character").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if model.modelData != nil {
                Button { model.export() } label: { ActionLabel(text: model.saved ? "Save another pose" : "Save 3D character", busy: model.exporting) }
                    .buttonStyle(PushButtonStyle()).disabled(!model.viewerLoaded || model.exporting)
                    .accessibilityIdentifier("save3DCharacterButton")
                    .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity).background(RallyStyle.paper)
            }
        }
        .confirmationDialog("Send this cutout to Tripo?", isPresented: $confirmsUpload, titleVisibility: .visible) {
            Button("Upload and use Tripo credits") {
                if let input { model.generate(png: input, address: serverAddress, token: accessToken, attribution: attribution) }
            }
        } message: {
            Text("This sends the selected person’s cutout to Tripo for one mesh generation and, if compatible, one auto-rig. Only upload images you have permission to use. Your API key stays on the server.")
        }
        .onDisappear { model.stopPolling() }
        .onChange(of: model.yaw) { _, _ in model.saved = false }
        .onChange(of: model.angles) { _, _ in model.saved = false }
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3D server").font(RallyStyle.font(14, .semibold))
            if let asset = model.asset {
                Text(asset.server).font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
            } else {
                TextField("http://localhost:3001", text: $serverAddress)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().rallyField()
                    .accessibilityLabel("3D server address")
            }
            SecureField("Server access token (optional on this Mac)", text: $accessToken)
                .textInputAutocapitalization(.never).autocorrectionDisabled().rallyField()
            Text("Run npm run start:3d in server/. Use your Mac’s Wi-Fi address on iPhone. This token is TRIPO_PROXY_TOKEN, never TRIPO_API_KEY.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Turn & pose").font(RallyStyle.font(20, .bold))
            HStack {
                Text("Turn character").font(RallyStyle.font(14))
                Spacer()
                Text("\(Int(model.yaw))°").monospacedDigit()
            }
            Slider(value: $model.yaw, in: -180...180, step: 1).accessibilityLabel("3D character rotation")
            if !model.bones.isEmpty {
                Toggle("Show skeleton", isOn: $model.showsSkeleton).font(RallyStyle.font(14))
                Picker("Joint", selection: $model.selectedBone) {
                    ForEach(model.bones) { bone in Text(bone.name).tag(bone.id) }
                }.pickerStyle(.menu)
                Picker("Rotation axis", selection: $model.selectedAxis) {
                    Text("X · bend").tag(0)
                    Text("Y · twist").tag(1)
                    Text("Z · swing").tag(2)
                }.pickerStyle(.segmented)
                HStack {
                    Slider(value: Binding(get: { model.currentAngle }, set: { model.setAngle($0) }), in: -180...180, step: 1)
                        .accessibilityLabel("3D joint angle")
                    Text("\(Int(model.currentAngle))°").font(RallyStyle.font(13)).monospacedDigit().frame(width: 42)
                }
                Text("\(model.bones.count) skin-weighted joints. Rotations are relative to the generated rig; no inverse kinematics or anatomical limits yet.")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            } else if model.viewerLoaded {
                Text("This mesh has no editable skeleton. Rotation still works.").font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
            }
            Button("Reset pose & turn") { model.angles = [:]; model.yaw = 0 }
                .font(RallyStyle.font(14, .semibold))
        }
        .padding(18).background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line))
        .disabled(!model.viewerLoaded)
    }
}
