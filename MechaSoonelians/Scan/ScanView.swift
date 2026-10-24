import ARKit
import RoomPlan
import SwiftUI

/// Scans the house one room at a time. All rooms share one ARSession, so they land in the
/// same coordinate space, and the world map saved at the end is in that space too.
final class ScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    @Published var rooms: [CapturedRoom] = []
    @Published var isScanning = false
    @Published var isSaving = false
    @Published var message: String?

    let arSession = ARSession()
    lazy var captureView: RoomCaptureView = {
        let view = RoomCaptureView(frame: .zero, arSession: arSession)
        view.delegate = self
        return view
    }()

    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError("not supported") }
    func encode(with coder: NSCoder) {}

    func startRoom() {
        message = nil
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    func finishRoom() {
        // Keep the ARSession running so the next room stays in the same coordinates.
        captureView.captureSession.stop(pauseARSession: false)
        isScanning = false
    }

    func finishHouse(onSaved: @escaping () -> Void) {
        if let status = arSession.currentFrame?.worldMappingStatus, status == .notAvailable || status == .limited {
            message = "Not enough of the house mapped yet. Walk around a bit more, then try again."
            return
        }
        isSaving = true
        Task { @MainActor in
            do {
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                // Apple's RoomPlan relocalization flow saves the world map after pausing the ARSession.
                // Maps saved while it was still running never relocalized in testing.
                arSession.pause()
                let worldMap = try await currentWorldMap()
                try HouseStore.saveHouse(structure: structure, rooms: rooms, worldMap: worldMap)
                onSaved()
                message = "Saved \(rooms.count) room(s)."
            } catch {
                message = "Couldn't save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    func stop() {
        if isScanning { captureView.captureSession.stop() }
        arSession.pause()
    }

    private func currentWorldMap() async throws -> ARWorldMap {
        try await withCheckedThrowingContinuation { continuation in
            arSession.getCurrentWorldMap { map, error in
                if let map {
                    continuation.resume(returning: map)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                }
            }
        }
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            message = "Room failed: \(error.localizedDescription)"
            return
        }
        rooms.append(processedResult)
    }
}

struct ScanView: View {
    var onSaved: () -> Void

    @StateObject private var controller = ScanController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureContainer(view: controller.captureView)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Eyebrow(text: "MAP YOUR PLAYGROUND")
                if let message = controller.message {
                    ErrorNotice(message: message)
                }

                if controller.isSaving {
                    ProgressView("Saving house…")
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if controller.isScanning {
                    Button("Done with this room") { controller.finishRoom() }
                        .buttonStyle(PushButtonStyle())
                } else {
                    Text(controller.rooms.isEmpty
                         ? "Stand in the first room and tap Scan."
                         : "Walk into the next room with the app open, then tap Scan.")
                        .font(RallyStyle.font(14))
                        .foregroundStyle(RallyStyle.muted)
                    HStack {
                        Button("Scan room \(controller.rooms.count + 1)") { controller.startRoom() }
                            .buttonStyle(PushButtonStyle())
                        if !controller.rooms.isEmpty {
                            Button("Finish house") {
                                controller.finishHouse {
                                    onSaved()
                                    dismiss()
                                }
                            }
                            .buttonStyle(PushButtonStyle(dark: true))
                        }
                    }
                }
            }
            .padding(20)
            .background(RallyStyle.paper, in: RoundedRectangle(cornerRadius: 24))
            .padding(24).frame(maxWidth: 540)
        }
        .foregroundStyle(RallyStyle.ink).tint(RallyStyle.ink).preferredColorScheme(.light)
        .navigationTitle("Scan your house")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { controller.stop() }
    }
}

private struct RoomCaptureContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
