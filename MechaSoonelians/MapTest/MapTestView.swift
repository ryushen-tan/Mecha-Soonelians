import ARKit
import RealityKit
import RoomPlan
import SwiftUI

/// Loads the saved house map and waits for ARKit to recognize the house. Cubes dropped after
/// that are saved in house coordinates, so after restarting the app they should come back in
/// the same real-world spot. That's the proof every phone can share one map.
///
/// The Debug menu can also make and reload a "quick map" with plain ARKit (no RoomPlan),
/// to tell a bad house scan apart from a relocalization problem.
final class MapTestController: NSObject, ObservableObject, ARSessionDelegate {
    enum Source { case house, newQuickMap, quickMap }

    @Published var source = Source.house
    @Published var isRelocalized = false
    @Published var status = "Loading house map…"
    @Published var cubeCount = 0
    @Published var canSaveQuickMap = false
    @Published var showScan = false {
        didSet { scanAnchor.isEnabled = showScan }
    }
    @Published var debugText = ""

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    private var cubes = HouseStore.loadTestCubes()
    // Until relocalized, world coordinates don't match the house yet, so nothing is shown.
    private let cubesAnchor = AnchorEntity(world: .zero)
    private let scanAnchor = AnchorEntity(world: .zero)

    private static let quickMapURL = HouseStore.documents.appendingPathComponent("quick.worldmap")
    private var mapInfo = "map: not loaded"
    private var trackingInfo = "-"
    private var startTime = Date()
    private var lastDebugUpdate = Date.distantPast

    override init() {
        super.init()
        arView.session.delegate = self
        scanAnchor.isEnabled = false
        arView.scene.addAnchor(cubesAnchor)
        arView.scene.addAnchor(scanAnchor)
        cubeCount = cubes.count
    }

    func start(_ source: Source) {
        self.source = source
        isRelocalized = false
        canSaveQuickMap = false
        cubesAnchor.isEnabled = false
        cubesAnchor.children.removeAll()
        scanAnchor.children.removeAll()

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        do {
            switch source {
            case .house:
                config.initialWorldMap = try HouseStore.loadWorldMap()
                status = "Look around the room you scanned…"
            case .quickMap:
                config.initialWorldMap = try Self.loadMap(from: Self.quickMapURL)
                status = "Look around where you made the quick map…"
            case .newQuickMap:
                status = "Walk around slowly for 30 seconds, then tap Save quick map."
            }
        } catch {
            status = "Couldn't load the map: \(error.localizedDescription)"
            return
        }
        mapInfo = config.initialWorldMap.map(Self.describe) ?? "map: none (making a quick map)"
        print("[MapTest]", mapInfo)

        arView.debugOptions = [.showFeaturePoints]
        startTime = Date()
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        arView.session.pause()
    }

    func saveQuickMap() {
        arView.session.getCurrentWorldMap { map, error in
            DispatchQueue.main.async {
                guard let map else {
                    self.status = "Couldn't save quick map: \(error?.localizedDescription ?? "unknown error")"
                    return
                }
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    try data.write(to: Self.quickMapURL)
                    self.mapInfo = Self.describe(map)
                    self.status = "Quick map saved. Debug → Test quick map."
                } catch {
                    self.status = "Couldn't save quick map: \(error.localizedDescription)"
                }
            }
        }
    }

    func handleTap(at point: CGPoint) {
        guard isRelocalized, source == .house else { return }
        guard let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first else {
            status = "No surface there. Try the floor or a table."
            return
        }
        cubes.append(hit.worldTransform)
        addCube(at: hit.worldTransform)
        saveCubes()
    }

    func clearCubes() {
        cubes.removeAll()
        cubesAnchor.children.removeAll()
        saveCubes()
    }

    private func saveCubes() {
        cubeCount = cubes.count
        do {
            try HouseStore.saveTestCubes(cubes)
        } catch {
            status = "Couldn't save cubes: \(error.localizedDescription)"
        }
    }

    private func addCube(at transform: simd_float4x4) {
        let cube = ModelEntity(
            mesh: .generateBox(size: 0.1, cornerRadius: 0.01),
            materials: [SimpleMaterial(color: .systemGreen, isMetallic: false)]
        )
        cube.transform = Transform(matrix: transform)
        // A raycast's Y axis is the surface normal; lift the cube so it sits on the surface.
        cube.position += simd_make_float3(transform.columns.1) * 0.05
        cubesAnchor.addChild(cube)
    }

    /// Draws the RoomPlan walls and furniture as see-through boxes. If they line up with the
    /// real room, the map loaded in the right place.
    private func addScan() {
        guard let structure = try? HouseStore.loadStructure() else { return }
        var wallMaterial = UnlitMaterial(color: .systemTeal)
        wallMaterial.blending = .transparent(opacity: 0.35)
        var objectMaterial = UnlitMaterial(color: .systemOrange)
        objectMaterial.blending = .transparent(opacity: 0.35)

        for wall in structure.walls {
            let box = ModelEntity(
                mesh: .generateBox(width: wall.dimensions.x, height: wall.dimensions.y, depth: 0.02),
                materials: [wallMaterial]
            )
            box.transform = Transform(matrix: wall.transform)
            scanAnchor.addChild(box)
        }
        for object in structure.objects {
            let box = ModelEntity(mesh: .generateBox(size: object.dimensions), materials: [objectMaterial])
            box.transform = Transform(matrix: object.transform)
            scanAnchor.addChild(box)
        }
    }

    private static func loadMap(from url: URL) throws -> ARWorldMap {
        let data = try Data(contentsOf: url)
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return map
    }

    /// The full extent includes stray far-off points, so also report the middle 90% of points.
    private static func describe(_ map: ARWorldMap) -> String {
        let points = map.rawFeaturePoints.points
        func core(_ axis: (simd_float3) -> Float) -> Float {
            let values = points.map(axis).sorted()
            guard values.count > 20 else { return 0 }
            return values[values.count * 95 / 100] - values[values.count * 5 / 100]
        }
        return String(
            format: "map: %d points, %d anchors\nfull: %.0f×%.0f×%.0f m\ncore: %.1f×%.1f×%.1f m",
            points.count, map.anchors.count,
            map.extent.x, map.extent.y, map.extent.z,
            core { $0.x }, core { $0.y }, core { $0.z }
        )
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard Date().timeIntervalSince(lastDebugUpdate) > 0.5 else { return }
        lastDebugUpdate = Date()
        canSaveQuickMap = source == .newQuickMap
            && (frame.worldMappingStatus == .extending || frame.worldMappingStatus == .mapped)
        debugText = [
            mapInfo,
            "tracking: \(trackingInfo)",
            "mapping: \(frame.worldMappingStatus.debugName)",
            "live points: \(frame.rawFeaturePoints?.points.count ?? 0)",
            String(format: "time: %.0fs", Date().timeIntervalSince(startTime)),
        ].joined(separator: "\n")
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        status = "AR error: \(error.localizedDescription)"
        print("[MapTest] session failed:", error)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingInfo = camera.trackingState.debugName
        print("[MapTest] tracking:", trackingInfo)
        switch camera.trackingState {
        case .normal:
            // Without an initial map there's nothing to recognize; tracking is just running.
            guard source != .newQuickMap else { return }
            if !isRelocalized {
                // With an initial world map, tracking only turns normal once the place is recognized.
                isRelocalized = true
                arView.debugOptions = []
                if source == .house {
                    cubes.forEach(addCube)
                    addScan()
                    cubesAnchor.isEnabled = true
                }
            }
            status = source == .house
                ? "Found your house ✅ Tap a surface to drop a cube."
                : "Found the quick map ✅"
        case .limited(.relocalizing):
            status = "Look around the room you scanned…"
        case .limited(.excessiveMotion):
            status = "Slow down a bit."
        case .limited(.insufficientFeatures):
            status = "Point at something with more detail."
        case .limited:
            status = "Hold on…"
        case .notAvailable:
            status = "Tracking isn't available on this device."
        }
    }
}

struct MapTestView: View {
    @StateObject private var controller = MapTestController()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(controller: controller)
                .ignoresSafeArea()

            VStack {
                Text(controller.debugText)
                    .font(.caption2.monospaced())
                    .padding(8)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            VStack(spacing: 12) {
                Text(controller.status)
                    .font(.callout)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

                if controller.source == .newQuickMap {
                    Button("Save quick map") { controller.saveQuickMap() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.canSaveQuickMap)
                } else if controller.isRelocalized && controller.source == .house {
                    HStack {
                        Toggle("Show scan", isOn: $controller.showScan)
                            .toggleStyle(.button)
                        Button("Clear cubes (\(controller.cubeCount))") { controller.clearCubes() }
                            .disabled(controller.cubeCount == 0)
                    }
                    .buttonStyle(.bordered)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .navigationTitle("Test house map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu("Debug") {
                Button("Test house map") { controller.start(.house) }
                Button("Make quick map") { controller.start(.newQuickMap) }
                Button("Test quick map") { controller.start(.quickMap) }
            }
        }
        .onAppear { controller.start(.house) }
        .onDisappear { controller.stop() }
    }
}

private extension ARCamera.TrackingState {
    var debugName: String {
        switch self {
        case .normal: "normal"
        case .notAvailable: "notAvailable"
        case .limited(.initializing): "limited (initializing)"
        case .limited(.relocalizing): "limited (relocalizing)"
        case .limited(.excessiveMotion): "limited (excessiveMotion)"
        case .limited(.insufficientFeatures): "limited (insufficientFeatures)"
        case .limited: "limited"
        }
    }
}

private extension ARFrame.WorldMappingStatus {
    var debugName: String {
        switch self {
        case .notAvailable: "notAvailable"
        case .limited: "limited"
        case .extending: "extending"
        case .mapped: "mapped"
        @unknown default: "unknown"
        }
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let controller: MapTestController

    func makeUIView(context: Context) -> ARView {
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        controller.arView.addGestureRecognizer(tap)
        return controller.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject {
        let controller: MapTestController
        init(controller: MapTestController) { self.controller = controller }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            controller.handleTap(at: gesture.location(in: controller.arView))
        }
    }
}
