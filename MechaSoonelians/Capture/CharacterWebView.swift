import SwiftUI
import WebKit

struct CharacterWebView: UIViewRepresentable {
    @ObservedObject var model: Character3DModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "character")
        let view = WKWebView(frame: .zero, configuration: configuration)
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
                        _ = try await webView.callAsyncJavaScript("await window.characterViewer.load(data, attribution)",
                            arguments: ["data": data.base64EncodedString(), "attribution": model.asset?.attribution ?? ""], in: nil, contentWorld: .page)
                    } catch { model.error = "Could not load the 3D model in the viewer." }
                }
            }
            guard model.viewerLoaded else { return }
            let arguments: [String: Any] = ["angles": model.angles, "yaw": model.yaw, "skeleton": model.showsSkeleton]
            let state = try? JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)
            guard state != lastPose else { return }
            lastPose = state
            Task {
                do {
                    _ = try await webView.callAsyncJavaScript("window.characterViewer.pose(angles, yaw, skeleton)", arguments: arguments, in: nil, contentWorld: .page)
                } catch { model.error = "Could not update the 3D pose." }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready": ready = true; update()
            case "loaded":
                if let value = body["value"], let data = try? JSONSerialization.data(withJSONObject: value),
                   let bones = try? JSONDecoder().decode([CharacterBone].self, from: data) {
                    model.bones = bones
                    model.selectedBone = bones.first?.id ?? 0
                    model.viewerLoaded = true
                    lastPose = nil
                    update()
                }
            case "error":
                model.error = body["value"] as? String ?? "3D viewer error."
                model.exporting = false
            case "exported":
                if let value = body["value"] as? [String: String], let mesh = value["model"], let thumbnail = value["thumbnail"] {
                    model.receiveExport(model: mesh, thumbnail: thumbnail)
                }
            default: break
            }
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
