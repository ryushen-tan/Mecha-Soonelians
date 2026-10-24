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
    /// Ghosts showing their 3D model rather than the flat cutout.
    private var modelGhosts: Set<UUID> = []
    private var loadingModels: Set<UUID> = []
    private var shownGhosts: Set<UUID> = []
    private var floorY: Float?
    private var isRunning = false
    /// What the session was started with, so the camera can be brought back without losing the house.
    private var configuration: ARWorldTrackingConfiguration?
    private var watchdog: Timer?
    /// The scanned walls, for putting hiders' backs against them.
    private(set) var walls: [GhostCapture.Wall] = []
    /// The scanned walls and furniture, so chameleons don't go inside them.
    private(set) var obstacles = RoomObstacles()

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
        // Lights 3D ghosts with the room's real lighting.
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        // Real people walking past should block ghosts behind them.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        configuration = config
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        trackingMessage = "Look around so your phone can find the house…"
        // If frames stop arriving (a covered or interrupted view), bring the camera back by itself.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let age = self.arView.session.currentFrame.map { ProcessInfo.processInfo.systemUptime - $0.timestamp }
            if age == nil || age! > 3 { self.restartCamera() }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        arView.session.pause()
        isRunning = false
    }

    /// Runs the session again with the same house map, without resetting where the phone thinks it is.
    /// Fixes a camera view that went black after being covered or interrupted.
    func restartCamera() {
        guard isRunning, let configuration else { return }
        arView.session.run(configuration)
        arView.setNeedsDisplay()
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

    /// Where a chameleon goes when the player points at this screen point: on a wall it stands on the
    /// floor with its back to the wall; on the floor or furniture it faces `facing`, else the player.
    func chameleonPlacement(at point: CGPoint, height: Float = ChameleonStore.height, facing: SIMD3<Float>? = nil) -> GhostPlacement? {
        guard isRelocalized, let frame = currentFrame,
              let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first else { return nil }
        let position = simd_make_float3(hit.worldTransform.columns.3)
        let camera = simd_make_float3(frame.camera.transform.columns.3)
        // A raycast result's Y axis is the surface normal.
        var normal = simd_make_float3(hit.worldTransform.columns.1)
        let onWall = abs(normal.y) < 0.5
        var origin = position
        var facing = facing ?? camera - position
        if onWall {
            normal.y = 0
            facing = simd_dot(normal, camera - position) < 0 ? -normal : normal
            // Line up with the scanned wall, so the body is just in front of it rather than in it.
            if let wall = obstacles.nearestWall(to: position, within: 0.25), simd_dot(wall.normal, facing) > 0.7 {
                origin = wall.point
                facing = wall.normal
            }
            origin.y = floorHeight(for: frame)
        }
        facing.y = 0
        guard simd_length(facing) > 0.01 else { return nil }
        return GhostPlacement(origin: origin, facing: simd_normalize(facing), onWall: onWall,
                              width: height / 2, height: height)
    }

    /// While set, a tap places a chameleon instead of tagging a ghost.
    var onTapPlace: ((CGPoint) -> Void)?

    // MARK: Ghosts

    /// Makes the scene show exactly these ghosts: the 3D model once it has arrived, else the flat cutout.
    func show(_ ghosts: [Ghost], images: [UUID: Data], models: [UUID: URL]) {
        let ids = Set(ghosts.map(\.id))
        shownGhosts = ids
        for (id, entity) in ghostEntities where !ids.contains(id) {
            entity.removeFromParent()
            ghostEntities[id] = nil
            foundGhosts.remove(id)
            modelGhosts.remove(id)
        }
        for ghost in ghosts {
            if ghost.hasModel, !modelGhosts.contains(ghost.id), !loadingModels.contains(ghost.id), let url = models[ghost.id] {
                if url.pathExtension == "body" {
                    if let paint = images[ghost.id], let data = try? Data(contentsOf: url),
                       let archive = try? JSONDecoder().decode(CharacterBodyArchive.self, from: data),
                       let body = ChameleonBody(archive: archive), let entity = makeChameleon(ghost, paint: paint, body: body) {
                        modelGhosts.insert(ghost.id)
                        place(entity, for: ghost.id)
                    }
                } else { loadModel(for: ghost, from: url) }
            }
            // A sprayed chameleon's image is its paint, so it only ever goes on the body.
            if ghostEntities[ghost.id] == nil, ghost.paintedBody, !ghost.hasModel,
               let image = images[ghost.id], let entity = makeChameleon(ghost, paint: image) {
                place(entity, for: ghost.id)
            }
            if ghostEntities[ghost.id] == nil, !ghost.paintedBody,
               let image = images[ghost.id],
               let entity = makeGhostEntity(ghost, image: image) {
                place(entity, for: ghost.id)
            }
            if ghost.foundBy != nil, !foundGhosts.contains(ghost.id), let entity = ghostEntities[ghost.id] {
                foundGhosts.insert(ghost.id)
                markFound(entity, height: ghost.height)
            }
        }
    }

    private func place(_ entity: Entity, for id: UUID) {
        ghostEntities[id]?.removeFromParent()
        houseAnchor.addChild(entity)
        ghostEntities[id] = entity
    }

    /// Swaps the flat cutout for the 3D model, standing where the hider put it.
    private func loadModel(for ghost: Ghost, from url: URL) {
        guard let floor = simd_float4x4(floats: ghost.floorTransform) else { return }
        loadingModels.insert(ghost.id)
        Task { @MainActor in
            defer { loadingModels.remove(ghost.id) }
            guard let model = try? await Entity(contentsOf: url) else { return }
            let container = Self.stand(model, floor: floor, height: ghost.height, flushBack: ghost.flushBack)
            container.name = ghost.id.uuidString
            // The ghost may have left the scene (retaken photo, new round) while this loaded.
            guard shownGhosts.contains(ghost.id) else { return }
            modelGhosts.insert(ghost.id)
            place(container, for: ghost.id)
            if foundGhosts.contains(ghost.id) { markFound(container, height: ghost.height) }
        }
    }

    /// A hider's chameleon in its pose, wearing their spray paint.
    private func makeChameleon(_ ghost: Ghost, paint: Data, body: ChameleonBody? = ChameleonBody.shared) -> Entity? {
        guard let floor = simd_float4x4(floats: ghost.floorTransform), let body,
              let pose = body.index(of: ghost.pose), let cgImage = UIImage(data: paint)?.cgImage,
              let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)),
              let model = try? body.entity(pose, paint: texture) else { return nil }
        let container = Self.stand(model, floor: floor, height: ghost.height, flushBack: ghost.flushBack)
        container.name = ghost.id.uuidString
        return container
    }

    /// Shows a chameleon at its spot before it's hidden, while it's being painted.
    func addPreview(_ model: Entity, placement: GhostPlacement) -> Entity {
        model.removeFromParent()
        model.transform = .identity
        let container = Self.stand(model, floor: placement.floorTransform, height: placement.height, flushBack: placement.flushBack)
        houseAnchor.addChild(container)
        return container
    }

    /// The model scaled to `height`, with its feet on the floor, centered left-right; its back on
    /// the wall (just in front of the wall's invisible blocker) or centered on the spot.
    private static func stand(_ model: Entity, floor: simd_float4x4, height: Float, flushBack: Bool) -> Entity {
        let bounds = model.visualBounds(relativeTo: nil)
        // The 3D editor normalizes every character to 1.75 m standing, so a crouch stays a crouch.
        let scale = height / 1.75
        model.scale = SIMD3(repeating: scale)
        let back = flushBack ? -bounds.min.z * scale + 0.015 : -bounds.center.z * scale
        model.position = SIMD3(-bounds.center.x * scale, -bounds.min.y * scale, back)

        let size = bounds.extents * scale
        let container = Entity()
        container.transform = Transform(matrix: floor)
        container.addChild(model)
        container.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: size)
                .offsetBy(translation: SIMD3(0, size.y / 2, flushBack ? size.z / 2 + 0.015 : 0)),
        ]))
        return container
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

    /// Tints a found cutout green; a found 3D ghost gets a green marker over its head instead.
    private func markFound(_ entity: Entity, height: Float) {
        var tinted = false
        for case let model as ModelEntity in entity.children {
            guard var material = model.model?.materials.first as? UnlitMaterial else { continue }
            material.color.tint = UIColor(red: 0.5, green: 1, blue: 0.5, alpha: 1)
            model.model?.materials = [material]
            tinted = true
        }
        guard !tinted else { return }
        let marker = ModelEntity(mesh: .generateSphere(radius: 0.07), materials: [UnlitMaterial(color: .systemGreen)])
        marker.position = [0, height + 0.15, 0]
        entity.addChild(marker)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if let onTapPlace {
            onTapPlace(gesture.location(in: arView))
            return
        }
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
            // Thin, so ghosts with their backs on the wall aren't cut into.
            let box = ModelEntity(
                mesh: .generateBox(width: wall.dimensions.x, height: wall.dimensions.y, depth: 0.02),
                materials: [OcclusionMaterial()]
            )
            box.transform = Transform(matrix: wall.transform)
            houseAnchor.addChild(box)
        }
        walls = structure.walls.map { GhostCapture.Wall(transform: $0.transform, width: $0.dimensions.x) }
        obstacles = RoomObstacles(structure)
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
        // Try once more: most failures are the camera being taken away for a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restartCamera() }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        restartCamera()
    }
}

struct ARGameViewContainer: UIViewRepresentable {
    let controller: ARGameController
    func makeUIView(context: Context) -> ARView { controller.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
