import SwiftUI

struct Character3DView: View {
    let input: Data?
    let attribution: String?
    let inputWarning: String?
    @StateObject private var model: Character3DModel
    @AppStorage("tripoServer") private var serverAddress = "http://localhost:3001"
    @State private var accessToken = ""
    @State private var confirmsUpload = false

    init(input: Data? = nil, attribution: String? = nil, inputWarning: String? = nil, asset: CharacterAsset? = nil) {
        self.input = input
        self.attribution = attribution
        self.inputWarning = inputWarning
        _model = StateObject(wrappedValue: Character3DModel(asset: asset))
    }

    var body: some View {
        Group {
            if model.modelData != nil { CharacterStudioView(model: model) }
            else { generationView }
        }
        .navigationTitle("3D character").navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stopPolling() }
    }

    private var generationView: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Eyebrow(text: "A CHARACTER FROM EVERY ANGLE")
                    Text("Meet your 3D self.").font(RallyStyle.font(32, .heavy)).tracking(-1)
                    Group {
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
                        if let inputWarning { ErrorNotice(message: inputWarning) }
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

}
