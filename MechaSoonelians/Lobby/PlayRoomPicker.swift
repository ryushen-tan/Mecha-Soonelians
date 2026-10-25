import RoomPlan
import SceneKit
import SwiftUI

// Hallmark · component: room picker · theme: Jelly · existing native tokens.
// Pre-emit critique: philosophy 4, hierarchy 4, execution 4, specificity 5, restraint 4, variety 4.
struct PlayRoomPicker: View {
    var onSelection: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [SavedRoom] = []
    @State private var focusedID: String?
    @State private var selectedID: String?
    @State private var adding = false
    @State private var previewReady = false
    @State private var error: String?
    @State private var selecting = false

    private var focusedRoom: SavedRoom? { rooms.first { $0.id == focusedID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    JellyWordmark()
                    Text("Choose your play room").font(JellyStyle.display(30))
                    Text("Explore the interior, then choose where everyone will play. You’ll need to be in that physical space.")
                        .font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
                    if let room = focusedRoom {
                        RoomInteriorPreview(url: room.modelURL, ready: $previewReady)
                            .id(room.id).frame(height: 280)
                            .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 24))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(JellyStyle.ink, lineWidth: 2))
                        HStack(alignment: .top) {
                            Text(room.name).font(JellyStyle.display(23))
                            Spacer()
                            if room.id == selectedID {
                                Label("Selected", systemImage: "checkmark.circle.fill")
                                    .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.blue)
                            }
                        }
                        Text("Drag to look around · Pinch to zoom")
                            .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                        Button {
                            selecting = true
                            error = nil
                            do {
                                try HouseStore.select(room)
                                onSelection()
                                dismiss()
                            } catch { self.error = "Couldn’t use this room. \(error.localizedDescription)" }
                            selecting = false
                        } label: {
                            HStack {
                                Text("Use this room")
                                Spacer()
                                if selecting { ProgressView() } else { Image(systemName: "arrow.right") }
                            }
                        }
                        .buttonStyle(JellyButtonStyle(fullWidth: true))
                        .disabled(!previewReady || selecting).accessibilityIdentifier("usePlayRoomButton")
                    } else {
                        Label("No saved rooms yet", systemImage: "house")
                            .font(JellyStyle.display(22)).padding(.vertical, 24)
                    }
                    if let error { JellyNotice(message: error) }
                    if !rooms.isEmpty {
                        Text("SAVED ROOMS").font(JellyStyle.body(12)).tracking(1)
                        ForEach(rooms) { room in
                            Button {
                                if focusedID != room.id { previewReady = false; focusedID = room.id }
                                error = nil
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "house")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(room.name).font(JellyStyle.body(16))
                                        Text(room.isBundled ? "Included with the app" : "Saved on this phone")
                                            .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                                    }
                                    Spacer()
                                    if focusedID == room.id { Image(systemName: "eye.fill").foregroundStyle(JellyStyle.blue) }
                                    if selectedID == room.id { Image(systemName: "checkmark").foregroundStyle(JellyStyle.blue) }
                                }
                                .padding(16).background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(
                                    focusedID == room.id ? JellyStyle.blue : JellyStyle.ink, lineWidth: 2))
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("playRoom_" + room.id)
                            .accessibilityAddTraits(focusedID == room.id ? .isSelected : [])
                        }
                    }
                    Button { adding = true } label: { Label("Add new room", systemImage: "plus") }
                        .buttonStyle(JellyButtonStyle(kind: .ghost, fullWidth: true))
                        .disabled(!RoomCaptureSession.isSupported).accessibilityIdentifier("addPlayRoomButton")
                    if !RoomCaptureSession.isSupported {
                        Text("Scanning a new room needs a LiDAR-equipped iPhone or iPad. You can still preview and select saved rooms here.")
                            .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                    }
                }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .background(JellyStyle.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add new play room")
                        .disabled(!RoomCaptureSession.isSupported)
                }
            }
            .sheet(isPresented: $adding) {
                NewPlayRoomView {
                    reload()
                    onSelection()
                }
            }
            .onAppear { reload() }
        }.foregroundStyle(JellyStyle.ink).tint(JellyStyle.blue)
    }

    private func reload() {
        rooms = HouseStore.rooms
        selectedID = HouseStore.selectedRoom?.id
        let nextID = selectedID ?? rooms.first?.id
        if focusedID != nextID { previewReady = false }
        focusedID = nextID
    }
}

private struct NewPlayRoomView: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Add a new room").font(JellyStyle.display(30))
                    Text("Give your play space a name, then scan its interior. You can include connected rooms in the same scan.")
                        .font(JellyStyle.body(15)).foregroundStyle(JellyStyle.muted)
                    TextField("Living room", text: $name).font(JellyStyle.body(18))
                        .modifier(JellyField(focused: false)).accessibilityLabel("Play room name")
                        .onChange(of: name) { _, value in name = String(value.prefix(60)) }
                    Text("Your existing rooms will stay in the gallery.")
                        .font(JellyStyle.body(13)).foregroundStyle(JellyStyle.muted)
                    Button { scanning = true } label: { Label("Scan interior", systemImage: "camera") }
                        .buttonStyle(JellyButtonStyle(fullWidth: true))
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(24)
            }.background(JellyStyle.background.ignoresSafeArea())
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
                .fullScreenCover(isPresented: $scanning) {
                    NavigationStack {
                        ScanView(roomName: name) {
                            onSaved()
                            scanning = false
                            dismiss()
                        }
                    }
                }
        }.foregroundStyle(JellyStyle.ink).tint(JellyStyle.blue)
    }
}

struct RoomInteriorPreview: View {
    let url: URL
    @Binding var ready: Bool
    @State private var scene: SCNScene?
    @State private var error: String?

    var body: some View {
        Group {
            if let scene {
                RoomInteriorCanvas(scene: scene).accessibilityLabel("Interactive 3D room interior")
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "house").font(.system(size: 40))
                    Text(error).font(JellyStyle.body(14)).multilineTextAlignment(.center)
                }.padding(24)
            } else { ProgressView("Loading interior…").font(JellyStyle.body(14)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            ready = false
            scene = nil
            error = nil
            do {
                let loaded = try SCNScene(url: url)
                let bounds = loaded.rootNode.boundingBox
                guard bounds.max.x > bounds.min.x, bounds.max.z > bounds.min.z else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                scene = loaded
                ready = true
            } catch { self.error = "The interior preview is unavailable. Try another saved room or scan this space again." }
        }
    }
}

private struct RoomInteriorCanvas: UIViewRepresentable {
    let scene: SCNScene
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(JellyStyle.paper)
        view.scene = scene
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        let bounds = scene.rootNode.boundingBox
        let center = SCNVector3((bounds.min.x + bounds.max.x) / 2,
                               (bounds.min.y + bounds.max.y) / 2, (bounds.min.z + bounds.max.z) / 2)
        let radius = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = Double(max(100, radius * 10))
        camera.position = SCNVector3(center.x + radius * 0.65, center.y + radius * 0.7, center.z + radius * 0.65)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        view.defaultCameraController.target = center
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {}
}
