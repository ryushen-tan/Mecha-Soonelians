import SwiftUI
import PhotosUI

struct Character3DView: View {
    let input: Data?
    let attribution: String?
    let inputWarning: String?
    @StateObject private var model: Character3DModel
    @AppStorage("tripoServer") private var serverAddress = HostedCharacterService.address
    @State private var accessToken = CharacterServiceSettings.saved.token
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
        .toolbar(model.modelData == nil ? .visible : .hidden, for: .navigationBar)
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
                TextField(HostedCharacterService.address, text: $serverAddress)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().rallyField()
                    .accessibilityLabel("3D server address")
            }
            SecureField("Server access token", text: $accessToken)
                .textInputAutocapitalization(.never).autocorrectionDisabled().rallyField()
            Text("Uses the hosted server by default. For a local one, run npm run start:3d in server/ and use your Mac’s Wi-Fi address on iPhone. This token is TRIPO_PROXY_TOKEN, never TRIPO_API_KEY.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
        }
    }

}

struct CharacterLaunchGate<Content: View>: View {
    @State private var hasCharacter = CharacterProfile.ready != nil
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder var content: () -> Content

    private var bypassSetup: Bool {
        let process = ProcessInfo.processInfo
        return !process.arguments.contains("--test-character-setup") &&
            (process.arguments.contains("-ui-testing") || process.environment["XCTestConfigurationFilePath"] != nil)
    }

    var body: some View {
        Group {
            if hasCharacter || bypassSetup {
                content()
            } else {
                CharacterSetupView { hasCharacter = CharacterProfile.ready != nil }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { hasCharacter = CharacterProfile.ready != nil }
        }
    }
}

struct CharacterSetupView: View {
    var onComplete: () -> Void
    @StateObject private var human = HumanEditorModel()
    @StateObject private var model: Character3DModel
    @State private var service = CharacterServiceSettings.saved
    @State private var photo: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var preparing = false
    @State private var importing = false
    @State private var message: String?
    @State private var confirmsRetake = false
    @State private var allowsNewCapture = false
    @State private var showsConnection = false
    @Environment(\.scenePhase) private var scenePhase

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        _model = StateObject(wrappedValue: Character3DModel(asset: CharacterProfile.candidate()))
    }

    private var working: Bool { model.busy || preparing || human.isProcessing || importing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Brand()
                Eyebrow(text: model.asset == nil ? "ONE-TIME CHARACTER SETUP" : "YOUR 3D SELF")
                Text(model.asset == nil ? "First, become\nthe character." : "Bringing you\ninto the game.")
                    .font(RallyStyle.font(38, .heavy)).tracking(-1.2)
                    .accessibilityIdentifier("characterSetupTitle")
                Text("Scan yourself once. We’ll cut out your full body, build your 3D model with Tripo, and rig it for the Pose wheel. Next time, your saved character is ready to play.")
                    .font(RallyStyle.font(16)).foregroundStyle(RallyStyle.muted)
                if model.modelData != nil {
                    CharacterWebView(model: model).frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 24)).allowsHitTesting(false)
                } else if let image = human.selectedHuman.map({ UIImage(cgImage: $0.cutout) }) ?? model.asset?.preview {
                    Image(uiImage: image).resizable().scaledToFit().frame(height: 240).frame(maxWidth: .infinity)
                        .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 24))
                } else {
                    Image(systemName: "figure.arms.open").font(.system(size: 110, weight: .ultraLight))
                        .frame(maxWidth: .infinity, minHeight: 160).foregroundStyle(RallyStyle.ink)
                        .background(RallyStyle.lime.opacity(0.3), in: RoundedRectangle(cornerRadius: 24))
                }
                if working {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(preparing ? "Preparing your poses and paint…" : human.isProcessing || importing ? "Finding your full-body cutout…" : model.status)
                            .font(RallyStyle.font(15, .semibold))
                    }
                    Text("You can close the app. Your request is saved, so reopening resumes the same job without paying for a duplicate.")
                        .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
                if let error = message ?? model.error { ErrorNotice(message: error) }
                if !working {
                    if model.asset != nil && !allowsNewCapture {
                        if model.modelData == nil {
                            connectionFields
                            Button { resume() } label: { ActionLabel(text: "Resume my character") }
                                .buttonStyle(PushButtonStyle()).accessibilityIdentifier("resumeCharacterSetupButton")
                        } else if model.asset?.rigged == true {
                            Button { Task { await prepare() } } label: { ActionLabel(text: "Prepare my saved character") }
                                .buttonStyle(PushButtonStyle())
                        } else {
                            ErrorNotice(message: model.warning ?? "Tripo couldn't rig this scan. We kept the mesh, but you'll need a new full-body capture to change poses.")
                        }
                        Button("Retake my scan") { confirmsRetake = true }.font(RallyStyle.font(14, .semibold))
                    } else {
                        connectionFields
                        if human.humans.count > 1 {
                            Text("More than one person found. Which one is you?").font(RallyStyle.font(15, .semibold))
                            HStack {
                                ForEach(Array(human.humans.enumerated()), id: \.element.id) { index, person in
                                    Button("Person \(index + 1)") { human.select(person.id) }.buttonStyle(.bordered)
                                }
                            }
                            Button { generate() } label: { ActionLabel(text: "Use this person") }
                                .buttonStyle(PushButtonStyle()).disabled(human.selectedHuman?.generationWarning != nil)
                        }
                        Text("Your cutout is uploaded to Tripo automatically after capture. Generation and rigging use your API credits.")
                            .font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
                        Button {
                            guard configureService() else { return }
                            showsCamera = true
                        } label: { ActionLabel(text: "Scan & create my 3D self") }
                            .buttonStyle(PushButtonStyle()).accessibilityIdentifier("scanCharacterSetupButton")
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Use a full-body photo", systemImage: "photo")
                                .font(RallyStyle.font(15, .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityIdentifier("importCharacterSetupButton")
                        Text("Stand head-to-toe in frame with your arms away from your body. Have a friend hold the phone. LiDAR is optional; hidden surfaces are AI-generated, not a measured body scan.")
                            .font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
                        Text("By scanning or choosing a photo, you allow us to send only your cutout to Tripo and use your API credits for generation and auto-rigging. Only upload yourself or someone who agrees. Your API key stays on the server.")
                            .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                    }
                }
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea()).foregroundStyle(RallyStyle.ink)
        .fullScreenCover(isPresented: $showsCamera) {
            PersonCameraView { data in
                showsCamera = false
                Task { await receive(data) }
            }
        }
        .task(id: photo) {
            guard let photo else { return }
            importing = true
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                importing = false
                await receive(data)
            } catch { importing = false; message = error.localizedDescription }
        }
        .task { if model.asset != nil && model.modelData == nil { resume() } }
        .onChange(of: model.viewerLoaded) { _, loaded in
            if loaded && model.asset?.rigged == true { Task { await prepare() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && model.asset != nil && model.modelData == nil && !model.busy { resume() }
        }
        .onDisappear { model.stopPolling() }
        .confirmationDialog("Start a new scan?", isPresented: $confirmsRetake, titleVisibility: .visible) {
            Button("Retake and create a new character") {
                model.stopPolling()
                model.modelData = nil
                model.asset = nil
                model.viewerLoaded = false
                model.error = nil
                message = nil
                allowsNewCapture = true
            }
        } message: { Text("Your old model is kept in Studio. A new capture starts a new paid Tripo job; the previous job is not cancelled or refunded.") }
    }

    private var connectionFields: some View {
        DisclosureGroup("3D server", isExpanded: $showsConnection) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("https://your-3d-server", text: $service.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().rallyField()
                    .accessibilityLabel("3D server address")
                SecureField("Server access token", text: $service.token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().rallyField()
                    .accessibilityLabel("3D server access token")
                Text("Run npm run start:3d in server/. On iPhone use your Mac’s Wi-Fi address, not localhost. Enter TRIPO_PROXY_TOKEN here, never your Tripo API key.")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }.padding(.top, 12)
        }.font(RallyStyle.font(14, .semibold))
    }

    private func configureService() -> Bool {
        do { try service.save(); message = nil; return true }
        catch { showsConnection = true; message = error.localizedDescription; return false }
    }

    private func receive(_ data: Data) async {
        guard configureService() else { return }
        importing = true
        defer { importing = false }
        do {
            let capture = try await Task.detached { try CaptureImage.decode(data) }.value
            await human.load(capture)
            guard let selected = human.selectedHuman else { message = human.status; return }
            if let warning = selected.generationWarning { message = warning; return }
            if human.humans.count == 1 { generate() }
        } catch { message = error.localizedDescription }
    }

    private func generate() {
        guard configureService(), human.selectedHuman?.generationWarning == nil, let png = human.make3DCutout() else { return }
        allowsNewCapture = false
        model.generate(png: png, address: service.address, token: service.token, attribution: nil, asProfile: true)
    }

    private func resume() {
        guard let asset = model.asset else { return }
        service.address = asset.server
        guard configureService() else { return }
        model.resume(token: service.token)
    }

    private func prepare() async {
        guard !preparing, model.viewerLoaded, let asset = model.asset, asset.rigged, let webView = model.webView else { return }
        preparing = true
        defer { preparing = false }
        do {
            guard let result = try await webView.callAsyncJavaScript("return window.characterViewer.bakeCharacter()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] else {
                throw CharacterFailure("Couldn't prepare the character for the room editor.")
            }
            try CharacterProfile.saveBody(result, for: asset)
            onComplete()
        } catch { message = error.localizedDescription }
    }
}
