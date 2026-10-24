import SwiftUI
import WebKit

struct CharacterWebView: UIViewRepresentable {
    @ObservedObject var model: Character3DModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "character")
        let view = CharacterCanvasWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = UIColor(RallyStyle.paper)
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        model.webView = view
        context.coordinator.webView = view
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "CharacterViewer") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { model.error = "The bundled 3D viewer is missing. Rebuild the app." }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update()
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        (view as? CharacterCanvasWebView)?.restoreNavigationGesture()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "character")
        view.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: Character3DModel
        weak var webView: WKWebView?
        private var ready = false
        private var loadedData: Data?
        private var lastPose: Data?

        init(model: Character3DModel) { self.model = model }

        func update() {
            guard ready, let webView else { return }
            if let data = model.modelData, loadedData != data {
                loadedData = data
                model.viewerLoaded = false
                Task {
                    do {
                        _ = try await webView.callAsyncJavaScript("await window.characterViewer.load(data, attribution, paint, scene); window.characterViewer.setRoom(room)",
                            arguments: ["data": data.base64EncodedString(), "attribution": model.asset?.attribution ?? "",
                                "paint": model.savedPaint ?? [:], "scene": model.savedScene ?? [:], "room": Self.roomData()], in: nil, contentWorld: .page)
                    } catch { model.error = "Could not load the 3D model in the viewer." }
                }
            }
            guard model.viewerLoaded else { return }
            let arguments: [String: Any] = ["editing": model.editing.dictionary, "angles": model.angles, "yaw": model.yaw,
                "skeleton": model.showsSkeleton, "immediate": UIAccessibility.isReduceMotionEnabled, "revision": model.placementRevision]
            let state = try? JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)
            guard state != lastPose else { return }
            lastPose = state
            Task {
                do {
                    _ = try await webView.callAsyncJavaScript("window.characterViewer.configure(editing, angles, yaw, skeleton, immediate, revision)", arguments: arguments, in: nil, contentWorld: .page)
                } catch { model.error = "Could not update the 3D pose." }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready": ready = true; update()
            case "loaded", "rig":
                if let value = body["value"], let data = try? JSONSerialization.data(withJSONObject: value),
                   let bones = try? JSONDecoder().decode([CharacterBone].self, from: data) {
                    model.bones = bones
                    if !bones.contains(where: { $0.id == model.selectedBone }) { model.selectedBone = bones.first?.id ?? 0 }
                    model.viewerLoaded = true
                    lastPose = nil
                    update()
                }
            case "error":
                model.error = body["value"] as? String ?? "3D viewer error."
                model.exporting = false
            case "exported":
                if let value = body["value"] as? [String: Any], let mesh = value["model"] as? String, let thumbnail = value["thumbnail"] as? String {
                    model.receiveExport(model: mesh, thumbnail: thumbnail, paint: value["paint"] as? [String: Any],
                        scene: value["scene"] as? [String: Any], boxes: value["boxes"] as? [[String: Any]] ?? [])
                }
            case "painted":
                if let value = body["value"] as? [String: Any] {
                    model.undoCount = (value["undo"] as? NSNumber)?.intValue ?? 0
                    model.redoCount = (value["redo"] as? NSNumber)?.intValue ?? 0
                    if model.undoCount > 0 { model.saved = false }
                }
            case "sampled": if let color = body["value"] as? String { model.editing.color = color; model.editing.tool = "paint" }
            case "capabilities": if let value = body["value"] as? [String: Any] { model.supportsHumanoid = value["humanoid"] as? Bool ?? false }
            case "clones": model.cloneCount = (body["value"] as? NSNumber)?.intValue ?? 0
            case "room": model.roomName = body["value"] as? String ?? "Practice room"
            case "warning": model.warning = body["value"] as? String
            case "placed":
                if let value = body["value"] as? [String: Any] {
                    if let revision = value["revision"] as? Int {
                        guard revision >= model.placementRevision else { return }
                        model.placementRevision = revision
                    }
                    var editing = model.editing
                    if let position = value["position"] as? [Double] { editing.position = position }
                    if let rotation = value["rotation"] as? [Double] { editing.rotation = rotation }
                    if let scale = value["scale"] as? Double { editing.scale = scale }
                    if let form = value["form"] as? String { editing.form = form }
                    if let preset = value["preset"] as? String { editing.preset = preset }
                    if let yaw = value["yaw"] as? Double { model.yaw = yaw }
                    if let angles = value["angles"] as? [String: [Double]] { model.angles = angles }
                    model.editing = editing
                    model.warning = value["warning"] as? String
                }
            case "wheel": model.showsWheel = body["value"] as? Bool ?? false
            case "selection": model.objectSelected = body["value"] as? Bool ?? false
            case "tool": if let tool = body["value"] as? String { model.editing.tool = tool }
            case "shot": if let ray = body["value"] as? [String: Any] { model.onShot?(ray) }
            case "taunt": model.onTaunt?()
            default: break
            }
        }

        private static func roomData() -> [String: Any] {
            guard let geometry = GameRoomGeometry.scannedHouse(), let data = try? JSONEncoder().encode(geometry),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            model.viewerLoaded = false
            model.exporting = false
            model.error = "The 3D viewer ran out of resources. Reopen this character to reload it."
        }
    }
}

private final class CharacterCanvasWebView: WKWebView {
    private weak var contentPop: UIGestureRecognizer?
    private var popWasEnabled = true

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { restoreNavigationGesture() }
        else { DispatchQueue.main.async { [weak self] in self?.protectCanvasGesture() } }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        protectCanvasGesture()
        return super.hitTest(point, with: event)
    }

    private func protectCanvasGesture() {
        guard #available(iOS 26.0, *) else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController,
               let gesture = controller.navigationController?.interactiveContentPopGestureRecognizer {
                if contentPop !== gesture {
                    restoreNavigationGesture()
                    contentPop = gesture
                    popWasEnabled = gesture.isEnabled
                }
                gesture.isEnabled = false
                return
            }
            responder = current.next
        }
    }

    func restoreNavigationGesture() {
        contentPop?.isEnabled = popWasEnabled
        contentPop = nil
    }
}
