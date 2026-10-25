import SwiftUI
import PhotosUI

struct Character3DView: View {
    let input: Data?
    let attribution: String?
    let inputWarning: String?
    @StateObject private var model: Character3DModel
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
                            Text("You can leave this page. Generation keeps running on the 3D server; resume from Studio → 3D characters. Closing this screen does not cancel Tripo or refund credits.")
                                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                        } else {
                            Button {
                                if model.asset == nil { confirmsUpload = true } else { model.resume() }
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
                if let input { model.generate(png: input, attribution: attribution) }
            }
        } message: {
            Text("This sends the selected person’s cutout to Tripo for one mesh generation and, if compatible, one auto-rig. Only upload images you have permission to use. Your API key stays on the server.")
        }
        .onChange(of: model.yaw) { _, _ in model.saved = false }
        .onChange(of: model.angles) { _, _ in model.saved = false }
    }

}

/// Owns the current job outside any sheet, so closing the gallery does not cancel it.
@MainActor
final class FigureLibrary: ObservableObject {
    static let shared = FigureLibrary()
    private static let pendingKey = "pendingPersonalFigureID"
    @Published private(set) var assets: [CharacterAsset] = []
    @Published private(set) var selected: CharacterAsset?
    @Published private(set) var readyIDs: Set<String> = []
    @Published private(set) var active: Character3DModel?
    @Published var failure: String?

    init() { refresh() }

    func refresh() {
        assets = CharacterAsset.all().filter { $0.attribution == nil }
        readyIDs = Set(assets.filter { CharacterProfile.isReady($0) }.map(\.id))
        selected = CharacterProfile.ready
    }

    @discardableResult func select(_ asset: CharacterAsset) -> Bool {
        guard CharacterProfile.isReady(asset) else { return false }
        CharacterProfile.remember(asset)
        refresh()
        return true
    }

    func track(_ model: Character3DModel) {
        guard active == nil, let asset = model.asset else { return }
        failure = nil
        UserDefaults.standard.set(asset.id, forKey: Self.pendingKey)
        active = model
        refresh()
    }

    func resume(_ asset: CharacterAsset) {
        guard active == nil else { return }
        let model = Character3DModel(asset: asset)
        track(model)
        if model.modelData == nil { model.resume() }
    }

    func restore() {
        refresh()
        guard active == nil, let id = UserDefaults.standard.string(forKey: Self.pendingKey),
              let asset = assets.first(where: { $0.id == id }) else { return }
        if CharacterProfile.isReady(asset) {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        } else {
            resume(asset)
        }
    }

    func finish(_ model: Character3DModel, error: String? = nil) {
        guard active === model else { return }
        failure = error
        // Failed jobs stay in the gallery for an explicit retry, without a permanent progress bar.
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        active = nil
        refresh()
    }
}

struct CharacterLaunchGate<Content: View>: View {
    var onSetupCancel: (() -> Void)? = nil
    @ObservedObject private var figures = FigureLibrary.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        if figures.selected != nil {
            content()
        } else {
            FigureGalleryView(onClose: onSetupCancel)
        }
    }
}

struct FigurePreparationWorker: View {
    @ObservedObject var figures = FigureLibrary.shared
    var body: some View {
        if let model = figures.active {
            FigurePreparationJob(model: model, figures: figures).id(ObjectIdentifier(model))
                .frame(width: 64, height: 64).opacity(0.01)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct FigurePreparationJob: View {
    @ObservedObject var model: Character3DModel
    let figures: FigureLibrary
    @State private var preparing = false

    var body: some View {
        Group {
            if model.modelData != nil && model.asset?.rigged == true {
                CharacterWebView(model: model)
            } else { Color.clear }
        }
        .onChange(of: model.busy, initial: true) { _, _ in checkFailure() }
        .onChange(of: model.error) { _, _ in checkFailure() }
        .task(id: model.viewerLoaded) {
            guard model.viewerLoaded, !preparing, let asset = model.asset,
                  asset.rigged, let webView = model.webView else { return }
            preparing = true
            do {
                guard let result = try await webView.callAsyncJavaScript(
                    "return window.characterViewer.bakeCharacter()", arguments: [:], in: nil,
                    contentWorld: .page) as? [String: Any] else {
                    throw CharacterFailure("Couldn't prepare this figure. Open the gallery to retry.")
                }
                try Task.checkCancellation()
                try CharacterProfile.saveBody(result, for: asset)
                figures.finish(model)
            } catch {
                figures.finish(model, error: error.localizedDescription)
            }
        }
    }

    private func checkFailure() {
        if let error = model.error {
            figures.finish(model, error: error)
        } else if !model.busy && model.modelData != nil && model.asset?.rigged == false {
            figures.finish(model, error: model.warning ??
                "This figure couldn't be rigged. Try a new full-body photo with arms away from your body.")
        }
    }
}

struct FigureBuildHeader: View {
    @ObservedObject private var figures = FigureLibrary.shared
    var body: some View {
        if let model = figures.active { FigureBuildProgress(model: model) }
    }
}

private struct FigureBuildProgress: View {
    @ObservedObject var model: Character3DModel
    @ObservedObject private var builds = CharacterBuilds.shared
    private var fraction: Double {
        let prefix = (model.asset?.id ?? "") + "/"
        let progress = builds.progress.first(where: { $0.key.hasPrefix(prefix) })?.value ?? 0.02
        return model.modelData == nil ? min(0.9, progress * 0.9) : 0.95
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.modelData == nil ? "Creating your 3D figure" : "Preparing your figure for play")
                Spacer()
                Text("\(Int(fraction * 100))%").monospacedDigit()
            }.font(JellyStyle.body(12))
            ProgressView(value: fraction).tint(JellyStyle.blue)
            Text("You can keep browsing. Your figure will be saved here.")
                .font(JellyStyle.body(11)).foregroundStyle(JellyStyle.muted)
        }
        .padding(14).background(JellyStyle.paper).foregroundStyle(JellyStyle.ink)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("figureGenerationHeader")
    }
}

struct FigureGalleryView: View {
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var figures = FigureLibrary.shared
    @StateObject private var audio = JellyAudio()
    @State private var adding = false
    @State private var preview: CharacterAsset?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    JellyWordmark()
                    Text("Your 3D figures").font(JellyStyle.display(32))
                    Text("Choose the figure you’ll hide in the game. Add a new scan or full-body photo with +.")
                        .font(JellyStyle.body(15)).foregroundStyle(JellyStyle.muted)
                    if let failure = figures.failure { JellyNotice(message: failure) }
                    if figures.assets.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "figure.arms.open").font(.system(size: 70))
                            Text("Make your first figure").font(JellyStyle.display(23))
                            Text("A ready 3D figure is required to enter a room.")
                                .font(JellyStyle.body(14)).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(28)
                        .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 24))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 16) {
                        ForEach(figures.assets) { asset in
                            Button { preview = asset } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let image = asset.preview {
                                        Image(uiImage: image).resizable().scaledToFit().frame(height: 145).frame(maxWidth: .infinity)
                                    } else {
                                        Image(systemName: "figure.arms.open").font(.system(size: 60)).frame(height: 145).frame(maxWidth: .infinity)
                                    }
                                    Text(asset.createdAt, style: .date).font(JellyStyle.body(13))
                                    Label(status(asset), systemImage: figures.selected?.id == asset.id ? "checkmark.circle.fill" : "cube")
                                        .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.blue)
                                }
                                .padding(14).background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 20))
                                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(
                                    figures.selected?.id == asset.id ? JellyStyle.blue : JellyStyle.ink, lineWidth: 2))
                            }.buttonStyle(.plain)
                        }
                    }
                    Button { adding = true } label: { Label("New 3D figure", systemImage: "plus") }
                        .buttonStyle(JellyButtonStyle(fullWidth: true))
                        .disabled(figures.active != nil).accessibilityIdentifier("addFigureButton")
                    if figures.active != nil {
                        Text("Finish this figure before adding another.").font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                    }
                }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .background(JellyStyle.background.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) { FigureBuildHeader() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(onClose == nil ? "Done" : "Back to lobby") { if let onClose { onClose() } else { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add 3D figure").disabled(figures.active != nil)
                }
            }
            .sheet(isPresented: $adding) { CharacterSetupView() }
            .sheet(item: $preview) { FigureDetailView(asset: $0) }
            .onAppear { figures.refresh() }
        }
        .foregroundStyle(JellyStyle.ink).tint(JellyStyle.blue).environmentObject(audio)
    }

    private func status(_ asset: CharacterAsset) -> String {
        if figures.selected?.id == asset.id { return "Selected" }
        if figures.readyIDs.contains(asset.id) { return "Ready to play" }
        if figures.active?.asset?.id == asset.id { return "Processing…" }
        if !asset.hasModel { return "Needs finishing" }
        return asset.rigged ? "Prepare for play" : "Needs a new scan"
    }
}

private struct FigureDetailView: View {
    let asset: CharacterAsset
    @StateObject private var model: Character3DModel
    @ObservedObject private var figures = FigureLibrary.shared
    @Environment(\.dismiss) private var dismiss
    init(asset: CharacterAsset) {
        self.asset = asset
        _model = StateObject(wrappedValue: Character3DModel(asset: asset))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your 3D figure").font(JellyStyle.display(30))
                    if model.modelData != nil {
                        CharacterWebView(model: model).frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 24))
                        Text("Drag to rotate your figure.").font(JellyStyle.body(13)).foregroundStyle(JellyStyle.muted)
                    } else if let image = asset.preview {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: 280).frame(maxWidth: .infinity)
                    }
                    if let error = model.error { JellyNotice(message: error) }
                    if figures.readyIDs.contains(asset.id) {
                        Button("Use this figure") { if figures.select(asset) { dismiss() } }
                            .buttonStyle(JellyButtonStyle(fullWidth: true))
                    } else if !asset.hasModel || asset.rigged {
                        Text("Finish preparing this figure before using it in a game.").font(JellyStyle.body(15))
                        Button("Prepare for play") { figures.resume(asset); dismiss() }
                            .buttonStyle(JellyButtonStyle(fullWidth: true)).disabled(figures.active != nil)
                    } else {
                        JellyNotice(message: model.warning ?? "This mesh couldn't be rigged and can't be placed in the game. Add a new full-body photo or scan from the gallery.")
                    }
                }.padding(24)
            }.background(JellyStyle.background.ignoresSafeArea())
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .foregroundStyle(JellyStyle.ink).tint(JellyStyle.blue)
    }
}

struct CharacterSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var figures = FigureLibrary.shared
    @StateObject private var human = HumanEditorModel()
    @StateObject private var model = Character3DModel(asset: nil)
    @State private var photo: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var importing = false
    @State private var message: String?
    private var working: Bool { importing || human.isProcessing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    JellyWordmark()
                    Text("Make a new\n3D figure").font(JellyStyle.display(36))
                        .accessibilityIdentifier("characterSetupTitle")
                    Text("Scan yourself or choose a full-body photo. Your finished figure will be saved in your gallery.")
                        .font(JellyStyle.body(16)).foregroundStyle(JellyStyle.muted)
                    if let person = human.selectedHuman {
                        Image(uiImage: UIImage(cgImage: person.cutout)).resizable().scaledToFit()
                            .frame(height: 240).frame(maxWidth: .infinity)
                    } else {
                        Image(systemName: "figure.arms.open").font(.system(size: 100))
                            .foregroundStyle(JellyStyle.blue).frame(maxWidth: .infinity, minHeight: 190)
                            .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 24))
                    }
                    if working { ProgressView("Finding your full-body cutout…").font(JellyStyle.body(14)) }
                    if let error = message ?? model.error { JellyNotice(message: error) }
                    if human.humans.count > 1 {
                        Text("Which person is you?").font(JellyStyle.display(20))
                        HStack {
                            ForEach(Array(human.humans.enumerated()), id: \.element.id) { index, person in
                                Button("Person \(index + 1)") { human.select(person.id); message = person.generationWarning }
                                    .buttonStyle(.bordered)
                            }
                        }
                        Button("Create this figure") { generate() }
                            .buttonStyle(JellyButtonStyle(fullWidth: true))
                            .disabled(human.selectedHuman?.generationWarning != nil)
                    }
                    Text("After capture, your cutout is sent to Tripo automatically. Generation and rigging use API credits.")
                        .font(JellyStyle.body(13)).foregroundStyle(JellyStyle.muted)
                    Button { showsCamera = true } label: { Label("Scan & create", systemImage: "camera") }
                        .buttonStyle(JellyButtonStyle(fullWidth: true)).accessibilityIdentifier("scanCharacterSetupButton")
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Upload a full-body photo", systemImage: "photo")
                            .font(JellyStyle.body(16)).frame(maxWidth: .infinity, minHeight: 48)
                    }.accessibilityIdentifier("importCharacterSetupButton")
                    Text("Keep your whole body in frame, with your arms away from your sides. Have a friend hold the phone. LiDAR is optional.")
                        .font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
                    Text("Only upload yourself or someone who agrees. Choosing a photo or scanning allows us to send your cutout for paid generation and rigging. Hidden surfaces are AI-generated.")
                        .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                }.padding(24).disabled(working || figures.active != nil)
            }
            .background(JellyStyle.background.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.disabled(working) } }
        }
        .foregroundStyle(JellyStyle.ink).tint(JellyStyle.blue)
        .interactiveDismissDisabled(working)
        .fullScreenCover(isPresented: $showsCamera) {
            PersonCameraView { data in showsCamera = false; Task { await receive(data) } }
        }
        .task(id: photo) {
            guard let photo else { return }
            importing = true
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                await receive(data)
            } catch { message = error.localizedDescription }
            importing = false
        }
    }

    private func receive(_ data: Data) async {
        importing = true
        message = nil
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
        guard figures.active == nil, human.selectedHuman?.generationWarning == nil,
              let png = human.make3DCutout() else { return }
        model.generate(png: png, attribution: nil, asProfile: false)
        guard model.asset != nil else { return }
        figures.track(model)
        dismiss()
    }
}
