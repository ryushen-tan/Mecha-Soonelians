import ARKit
import RealityKit
import RoomPlan
import SwiftUI

/// The in-game AR view: recognizes the house from the shared map, hides ghosts behind the
/// scanned walls, draws ghosts, and reports taps on them.
final class ARGameController: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var isRelocalized = false
    @Published private(set) var trackingMessage = "Loading house map…"

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    var onTapGhost: ((UUID) -> Void)?

    // Until relocalized, world coordinates don't match the house yet, so nothing is shown.
    private let houseAnchor = AnchorEntity(world: .zero)
    private var ghostEntities: [UUID: Entity] = [:]
    private var foundGhosts: Set<UUID> = []
    private var floorY: Float?
    private var isRunning = false

    override init() {
        super.init()
        arView.session.delegate = self
        houseAnchor.isEnabled = false
        arView.scene.addAnchor(houseAnchor)
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    func start(mapURL: URL, structureURL: URL) {
        guard !isRunning else { return }
        let map: ARWorldMap
        do {
            let data = try Data(contentsOf: mapURL)
            guard let loaded = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            map = loaded
        } catch {
            trackingMessage = "Couldn't load the house map: \(error.localizedDescription)"
            return
        }
        isRunning = true
        addWalls(from: structureURL)

        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = map
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        // Real people walking past should block ghosts behind them.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        trackingMessage = "Look around so your phone can find the house…"
    }

    func stop() {
        arView.session.pause()
        isRunning = false
    }

    var currentFrame: ARFrame? { arView.session.currentFrame }

    /// The floor height in house coordinates: the scanned floor, else a detected floor plane,
    /// else a guess from the camera height.
    func floorHeight(for frame: ARFrame) -> Float {
        if let floorY { return floorY }
        let floors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal && $0.classification == .floor }
            .map { $0.transform.columns.3.y }
        return floors.min() ?? frame.camera.transform.columns.3.y - 1.3
    }

    // MARK: Ghosts

    /// Makes the scene show exactly these ghosts.
    func show(_ ghosts: [Ghost], images: [UUID: Data]) {
        let ids = Set(ghosts.map(\.id))
        for (id, entity) in ghostEntities where !ids.contains(id) {
            entity.removeFromParent()
            ghostEntities[id] = nil
            foundGhosts.remove(id)
        }
        for ghost in ghosts {
            if ghostEntities[ghost.id] == nil,
               let image = images[ghost.id],
               let entity = makeGhostEntity(ghost, image: image) {
                houseAnchor.addChild(entity)
                ghostEntities[ghost.id] = entity
            }
            if ghost.foundBy != nil, !foundGhosts.contains(ghost.id), let entity = ghostEntities[ghost.id] {
                foundGhosts.insert(ghost.id)
                markFound(entity)
            }
        }
    }

    private func makeGhostEntity(_ ghost: Ghost, image: Data) -> Entity? {
        guard let transform = simd_float4x4(floats: ghost.transform),
              let cgImage = UIImage(data: image)?.cgImage,
              let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) else { return nil }

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        material.opacityThreshold = 0.5

        // A plane only faces one way, so add a second one facing back.
        let mesh = MeshResource.generatePlane(width: ghost.width, height: ghost.height)
        let front = ModelEntity(mesh: mesh, materials: [material])
        let back = ModelEntity(mesh: mesh, materials: [material])
        back.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])

        let ghostEntity = Entity()
        ghostEntity.name = ghost.id.uuidString
        ghostEntity.transform = Transform(matrix: transform)
        ghostEntity.addChild(front)
        ghostEntity.addChild(back)
        ghostEntity.components.set(CollisionComponent(shapes: [.generateBox(width: ghost.width, height: ghost.height, depth: 0.05)]))
        return ghostEntity
    }

    private func markFound(_ entity: Entity) {
        for case let model as ModelEntity in entity.children {
            guard var material = model.model?.materials.first as? UnlitMaterial else { continue }
            material.color.tint = UIColor(red: 0.5, green: 1, blue: 0.5, alpha: 1)
            model.model?.materials = [material]
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        var entity = arView.entity(at: gesture.location(in: arView))
        while let current = entity {
            if let id = UUID(uuidString: current.name), ghostEntities[id] != nil {
                onTapGhost?(id)
                return
            }
            entity = current.parent
        }
    }

    // MARK: Walls

    /// Invisible copies of the scanned walls hide ghosts in other rooms, even on phones without LiDAR.
    private func addWalls(from structureURL: URL) {
        guard let data = try? Data(contentsOf: structureURL),
              let structure = try? JSONDecoder().decode(CapturedStructure.self, from: data) else { return }
        for wall in structure.walls {
            let box = ModelEntity(
                mesh: .generateBox(width: wall.dimensions.x, height: wall.dimensions.y, depth: 0.1),
                materials: [OcclusionMaterial()]
            )
            box.transform = Transform(matrix: wall.transform)
            houseAnchor.addChild(box)
        }
        floorY = structure.floors.map { $0.transform.columns.3.y }.min()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            if !isRelocalized {
                // With an initial world map, tracking only turns normal once the house is recognized.
                isRelocalized = true
                houseAnchor.isEnabled = true
            }
            trackingMessage = "Found the house ✅"
        case .limited(.relocalizing):
            trackingMessage = "Look around so your phone can find the house…"
        case .limited(.excessiveMotion):
            trackingMessage = "Slow down a bit."
        case .limited(.insufficientFeatures):
            trackingMessage = "Point at something with more detail."
        case .limited:
            trackingMessage = "Hold on…"
        case .notAvailable:
            trackingMessage = "AR isn't available on this phone."
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        trackingMessage = "AR error: \(error.localizedDescription)"
    }
}

struct ARGameViewContainer: UIViewRepresentable {
    let controller: ARGameController
    func makeUIView(context: Context) -> ARView { controller.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
