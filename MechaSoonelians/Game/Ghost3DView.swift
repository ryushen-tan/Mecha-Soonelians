import SwiftUI
import WebKit

/// Turns a hider's cutout into a 3D model on the Mac's Tripo server, then lets them paint it in
/// the bundled 3D viewer and exports it as USDZ for RealityKit.
@MainActor
final class GhostSculptor: ObservableObject {
    @Published var status = "Sending your photo to the 3D maker…"
    @Published var modelData: Data?
    @Published var error: String?
    @Published var viewerLoaded = false
    @Published var exporting = false
    @Published var painting = true
    @Published var color = UIColor.gray
    @Published var brushSize = 0.02

    weak var webView: WKWebView?
    var onExported: ((Data) -> Void)?
    private var work: Task<Void, Never>?
    private let requestID = UUID().uuidString

    func generate(png: Data, server: ModelServer) {
        work = Task {
            do {
                let api = try CharacterAPI(address: server.address, accessToken: server.token)
                // The photo already has the hiding pose, so skip rigging.
                var job = try JSONDecoder().decode(CharacterJob.self, from: try await api.request(
                    "characters", png: png, id: requestID, headers: ["X-Rig": "0"]))
                while job.status != "ready" {
                    if job.status == "failed" { throw CharacterFailure(job.error ?? "Tripo couldn't build your 3D model.") }
                    status = "\(job.stage.capitalized) · \(Int(job.progress))%"
                    try await Task.sleep(for: .seconds(3))
                    job = try JSONDecoder().decode(CharacterJob.self, from: try await api.request("characters/\(requestID)"))
                }
                status = "Downloading your 3D self…"
                let data = try await api.request("characters/\(requestID)/model")
                guard data.count >= 12, data.prefix(4) == Data("glTF".utf8) else {
                    throw CharacterFailure("The 3D server didn't send back a model.")
                }
                modelData = data
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() { work?.cancel() }

    func undo() {
        Task { _ = try? await webView?.callAsyncJavaScript("window.characterViewer.undoPaint()", arguments: [:], in: nil, contentWorld: .page) }
    }

    func export() {
        guard viewerLoaded, !exporting else { return }
        exporting = true
        error = nil
        Task {
            do {
                _ = try await webView?.callAsyncJavaScript("await window.characterViewer.exportUSDZ()", arguments: [:], in: nil, contentWorld: .page)
            } catch {
                exporting = false
                self.error = "Couldn't export your 3D ghost."
            }
        }
    }

    fileprivate func receiveExport(_ base64: String) {
        exporting = false
        guard let data = Data(base64Encoded: base64) else {
            error = "Couldn't read your 3D ghost."
            return
        }
        onExported?(data)
    }

    fileprivate var brushArguments: [String: Any] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        let hex = String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        return ["painting": painting, "color": hex, "size": brushSize]
    }
}

struct Ghost3DView: View {
    let capture: GhostCapture
    @ObservedObject var sculptor: GhostSculptor
    var onUse2D: () -> Void

    @State private var pickingFromPhoto = false

    var body: some View {
        VStack(spacing: 0) {
            if sculptor.modelData != nil {
                GhostSculptWebView(sculptor: sculptor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Your 3D ghost. Paint it with one finger, or switch to Turn to look around it.")
                paintControls
            } else {
                waiting
            }
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .foregroundStyle(RallyStyle.ink)
        .sheet(isPresented: $pickingFromPhoto) { photoPicker }
    }

    private var waiting: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(decorative: capture.person, scale: 1)
                .resizable().scaledToFit()
                .frame(maxHeight: 280)
            if let error = sculptor.error {
                ErrorNotice(message: error)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(sculptor.status).font(RallyStyle.font(16, .semibold))
                }
                Text("Building your 3D self takes a few minutes. Stay on this screen; your spot is already saved.")
                    .font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button { onUse2D() } label: { ActionLabel(text: "Use a flat cutout instead") }
                .buttonStyle(PushButtonStyle(dark: true))
        }
        .padding(24)
    }

    private var paintControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: sculptor.painting ? "PAINT TO MATCH WHERE YOU'RE HIDING" : "DRAG TO TURN, PINCH TO ZOOM")
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(sculptor.color))
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(RallyStyle.ink, lineWidth: 2))
                    .accessibilityLabel("Current color")
                tool(sculptor.painting ? "paintbrush.pointed.fill" : "rotate.3d", label: sculptor.painting ? "Painting. Tap to turn instead." : "Turning. Tap to paint instead.", active: sculptor.painting) {
                    sculptor.painting.toggle()
                }
                tool("eyedropper", label: "Pick a color from your photo", active: false) { pickingFromPhoto = true }
                ColorPicker("Color", selection: Binding(get: { Color(sculptor.color) }, set: { sculptor.color = UIColor($0) }))
                    .labelsHidden()
                tool("arrow.uturn.backward", label: "Undo", active: false) { sculptor.undo() }
            }
            HStack {
                Image(systemName: "paintbrush.pointed").accessibilityHidden(true)
                Slider(value: $sculptor.brushSize, in: 0.005...0.08).tint(RallyStyle.ink)
                    .accessibilityLabel("Brush size")
            }
            if let error = sculptor.error { ErrorNotice(message: error) }
            Button { sculptor.export() } label: { ActionLabel(text: "Place 3D ghost", busy: sculptor.exporting) }
                .buttonStyle(PushButtonStyle())
                .disabled(!sculptor.viewerLoaded || sculptor.exporting)
            Button("Use a flat cutout instead", action: onUse2D)
                .font(RallyStyle.font(14, .semibold))
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(RallyStyle.surface)
    }

    private var photoPicker: some View {
        VStack(spacing: 16) {
            Eyebrow(text: "TAP WHAT'S BEHIND YOU")
            GeometryReader { geo in
                let size = CGSize(width: capture.photo.width, height: capture.photo.height)
                let scale = min(geo.size.width / size.width, geo.size.height / size.height)
                Image(decorative: capture.photo, scale: 1).resizable()
                    .frame(width: size.width * scale, height: size.height * scale)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        sculptor.color = PaintView.color(at: CGPoint(x: location.x / scale, y: location.y / scale), in: capture.photo)
                        pickingFromPhoto = false
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .background(RallyStyle.paper.ignoresSafeArea())
        .presentationDetents([.large])
    }

    private func tool(_ systemImage: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 40)
                .background(active ? RallyStyle.lime : RallyStyle.line.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .rallyHover(cornerRadius: 12)
        .accessibilityLabel(label)
    }
}

/// Ryu's bundled three.js character viewer, driven for painting and USDZ export.
private struct GhostSculptWebView: UIViewRepresentable {
    @ObservedObject var sculptor: GhostSculptor

    func makeCoordinator() -> Coordinator { Coordinator(sculptor: sculptor) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "character")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = UIColor(RallyStyle.paper)
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        sculptor.webView = view
        context.coordinator.webView = view
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "CharacterViewer") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { sculptor.error = "The 3D viewer is missing from the app. Rebuild it." }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update()
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "character")
        view.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let sculptor: GhostSculptor
        weak var webView: WKWebView?
        private var ready = false
        private var loaded = false
        private var lastBrush: NSDictionary?

        init(sculptor: GhostSculptor) { self.sculptor = sculptor }

        func update() {
            guard ready, let webView else { return }
            if !loaded, let data = sculptor.modelData {
                loaded = true
                Task {
                    do {
                        _ = try await webView.callAsyncJavaScript("await window.characterViewer.load(data, '')",
                            arguments: ["data": data.base64EncodedString()], in: nil, contentWorld: .page)
                    } catch { sculptor.error = "Couldn't show your 3D model." }
                }
            }
            guard sculptor.viewerLoaded else { return }
            let brush = sculptor.brushArguments
            guard lastBrush != brush as NSDictionary else { return }
            lastBrush = brush as NSDictionary
            Task {
                _ = try? await webView.callAsyncJavaScript(
                    "window.characterViewer.setPainting(painting); window.characterViewer.setBrush(color, size)",
                    arguments: brush, in: nil, contentWorld: .page)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                update()
            case "loaded":
                sculptor.viewerLoaded = true
                lastBrush = nil
                update()
            case "usdz":
                if let value = body["value"] as? String { sculptor.receiveExport(value) }
            case "error":
                sculptor.error = body["value"] as? String ?? "3D viewer error."
                sculptor.exporting = false
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            sculptor.viewerLoaded = false
            sculptor.exporting = false
            sculptor.error = "The 3D viewer ran out of memory. Use a flat cutout, or retake your photo."
        }
    }
}
