import ARKit
import AVFoundation
import RealityKit
import RoomPlan
import SwiftUI

/// The in-game AR view: recognizes the house from the shared map, hides ghosts behind the
/// scanned walls, draws ghosts, and reports taps on them.
final class ARGameController: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var isRelocalized = false
    @Published private(set) var trackingMessage = "Loading house map…"

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    // Until relocalized, world coordinates don't match the house yet, so nothing is shown.
    private let houseAnchor = AnchorEntity(world: .zero)
    private var ghostEntities: [UUID: Entity] = [:]
    private var foundGhosts: Set<UUID> = []
    /// Ghosts showing their 3D model rather than the flat cutout.
    private var modelGhosts: Set<UUID> = []
    private var loadingModels: Set<UUID> = []
    private var shownGhosts: Set<UUID> = []
    private struct PaintTarget {
        let model: ModelEntity
        let surface: BodySurface
        let original: TextureResource?
    }
    private var paintTargets: [UUID: PaintTarget] = [:]
    private var lastShot: TimeInterval = 0
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
        guard isRunning, let configuration, let resume = configuration.copy() as? ARWorldTrackingConfiguration else { return }
        // The house map is already loaded into the running session. Giving it again would send the phone
        // back to searching for the house, so resume without it and without resetting tracking.
        resume.initialWorldMap = nil
        arView.session.run(resume)
        arView.setNeedsDisplay()
    }

    var currentFrame: ARFrame? { arView.session.currentFrame }

    // MARK: Chirps

    private var heardChirps: Set<String> = []
    /// Where the latest chirp came from (house coordinates) and when, for the on-screen arrow.
    @Published private(set) var lastChirp: (position: SIMD3<Float>, at: Date)?

    /// Which way to turn toward the latest chirp, for 1 s after it: `angle` in radians, 0 straight
    /// ahead and positive to the left (on the floor plane), and how far away it is in metres.
    func chirpDirection(now: Date = Date()) -> (angle: Double, distance: Float)? {
        guard let chirp = lastChirp, now.timeIntervalSince(chirp.at) < 1, let frame = currentFrame else { return nil }
        let camera = frame.camera.transform
        var forward = -simd_make_float3(camera.columns.2)
        var toward = chirp.position - simd_make_float3(camera.columns.3)
        forward.y = 0
        toward.y = 0
        let distance = simd_length(toward)
        guard simd_length(forward) > 0.01, distance > 0.01 else { return (0, distance) }
        forward = simd_normalize(forward)
        let angle = atan2(Double(simd_cross(forward, toward).y), Double(simd_dot(forward, toward)))
        return (angle, distance)
    }
    private lazy var chirpSound: AudioFileResource? = Self.makeChirpSound()

    /// Plays a chirp from where this ghost hides, as 3D sound: it gets louder as you get closer and comes
    /// from its direction, so the seeker can turn toward it. Each chirp plays once.
    func play(_ chirp: Chirp, ghost: Ghost) {
        guard !heardChirps.contains(chirp.id), chirp.age < 6_000 else { return }
        heardChirps.insert(chirp.id)
        guard let floor = simd_float4x4(floats: ghost.floorTransform) else { return }
        guard let sound = chirpSound else {
            // No sound available: still point the way.
            lastChirp = (simd_make_float3(floor.columns.3) + SIMD3(0, ghost.height * 0.8, 0), Date())
            return
        }
        let source = Entity()
        source.transform = Transform(matrix: floor)
        source.position.y += ghost.height * 0.8
        source.components.set(SpatialAudioComponent(gain: 6, directLevel: 0, reverbLevel: -6))
        houseAnchor.addChild(source)
        lastChirp = (source.position, Date())
        source.playAudio(sound)
        // A second, louder call a moment later makes the direction easier to place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { source.playAudio(sound) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { source.removeFromParent() }
    }

    /// A short bird-like double chirp, made in code so no sound file has to ship.
    static func makeChirpSound() -> AudioFileResource? {
        let rate = 44_100.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp.caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
            let length = AVAudioFrameCount(rate * 0.42)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
                  let samples = buffer.floatChannelData?[0] else { return nil }
            buffer.frameLength = length
            var phase = 0.0
            for i in 0..<Int(length) {
                let t = Double(i) / rate
                // Two quick upward sweeps, 2.2 kHz to 4.4 kHz, each 0.16 s with a soft envelope.
                let note = t < 0.18 ? t : t - 0.24
                let inNote = note >= 0 && note < 0.16
                let frequency = 2_200 + 2_200 * min(1, max(0, note / 0.16))
                phase += 2 * .pi * frequency / rate
                let envelope = inNote ? sin(.pi * note / 0.16) : 0
                samples[i] = Float(sin(phase) * envelope * 0.9)
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            } catch { return nil }
        }
        return try? AudioFileResource.load(contentsOf: url, inputMode: .spatial, loadingStrategy: .preload, shouldLoop: false)
    }

    // MARK: What the seeker can see

    private var wallBoxes: [(transform: simd_float4x4, size: SIMD2<Float>)] = []

    /// The ghosts on screen right now: in front of the camera, inside the frame, within 12 m, and not
    /// behind a scanned wall. Found ghosts don't count.
    func ghostsInView(_ ghosts: [Ghost]) -> [UUID] {
        guard isRelocalized, let frame = currentFrame else { return [] }
        let camera = simd_make_float3(frame.camera.transform.columns.3)
        let forward = -simd_make_float3(frame.camera.transform.columns.2)
        let bounds = arView.bounds
        return ghosts.compactMap { ghost in
            guard ghost.foundBy == nil, ghostEntities[ghost.id] != nil,
                  let floor = simd_float4x4(floats: ghost.floorTransform) else { return nil }
            let center = simd_make_float3(floor.columns.3) + SIMD3(0, ghost.height * 0.5, 0)
            let offset = center - camera
            let distance = simd_length(offset)
            guard distance > 0.2, distance < 12, simd_dot(offset / distance, forward) > 0.2,
                  let point = arView.project(center), bounds.contains(point) else { return nil }
            return blockedByWall(from: camera, to: center) ? nil : ghost.id
        }
    }

    /// Whether a scanned wall stands between two points (ignoring a wall the ghost has its back to).
    private func blockedByWall(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Bool {
        for wall in wallBoxes {
            let inverse = wall.transform.inverse
            let a = simd_make_float3(inverse * SIMD4(start, 1)), b = simd_make_float3(inverse * SIMD4(end, 1))
            guard (a.z > 0) != (b.z > 0) else { continue }
            let t = a.z / (a.z - b.z)
            // Right at the ghost means the wall behind it, not one in the way.
            guard t < 0.97, simd_length(end - start) * (1 - t) > 0.15 else { continue }
            let hit = a + (b - a) * t
            if abs(hit.x) < wall.size.x / 2, abs(hit.y) < wall.size.y / 2 { return true }
        }
        return false
    }

    /// How many ghosts are in the scene right now.
    var shownGhostCount: Int { ghostEntities.count }

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
    /// Found figures stay visible with their original skin and a green marker.
    func show(_ ghosts: [Ghost], images: [UUID: Data], models: [UUID: URL]) {
        let ids = Set(ghosts.map(\.id))
        shownGhosts = ids
        for (id, entity) in ghostEntities where !ids.contains(id) {
            entity.removeFromParent()
            ghostEntities[id] = nil
            foundGhosts.remove(id)
            modelGhosts.remove(id)
            paintTargets[id] = nil
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
                revealPaint(for: ghost.id)
                markFound(entity, height: ghost.height)
            }
        }
    }

    private func place(_ entity: Entity, for id: UUID) {
        ghostEntities[id]?.removeFromParent()
        houseAnchor.addChild(entity)
        ghostEntities[id] = entity
        // A late model replacing a cutout must receive the confirmed reveal too.
        foundGhosts.remove(id)
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
            let wasFound = foundGhosts.contains(ghost.id)
            place(container, for: ghost.id)
            if wasFound {
                foundGhosts.insert(ghost.id)
                markFound(container, height: ghost.height)
            }
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
        let original = body.initialTexture.flatMap { try? TextureResource(image: $0, options: .init(semantic: .color)) }
        paintTargets[ghost.id] = PaintTarget(model: model, surface: BodySurface(body.mesh(pose), textureSize: PaintCanvas.size), original: original)
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

    private func revealPaint(for id: UUID) {
        guard let target = paintTargets[id] else { return }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: target.original.map { .init($0) })
        target.model.model?.materials = [material]
    }

    /// Marks the find without tinting or hiding the player's original appearance.
    private func markFound(_ entity: Entity, height: Float) {
        guard entity.findEntity(named: "found-marker") == nil else { return }
        let marker = ModelEntity(mesh: .generateSphere(radius: 0.07), materials: [UnlitMaterial(color: .systemGreen)])
        marker.name = "found-marker"
        marker.position = [0, height + 0.15, 0]
        entity.addChild(marker)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if let onTapPlace {
            onTapPlace(gesture.location(in: arView))
            return
        }
    }

    /// Fires through the screen center. Painted bodies use their real mesh, not their bounding box.
    func shoot() -> UUID? {
        let now = CACurrentMediaTime()
        guard isRelocalized, now - lastShot >= 0.25,
              let ray = arView.ray(through: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)) else { return nil }
        lastShot = now
        let direction = simd_normalize(ray.direction)
        var distance: Float = 12
        // Real-world reconstructed surfaces also stop a shot before a hidden body.
        if let surface = arView.raycast(from: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY), allowing: .existingPlaneGeometry, alignment: .any).first {
            distance = min(distance, simd_distance(ray.origin, simd_make_float3(surface.worldTransform.columns.3)))
        }
        let hit = shotTarget(from: ray.origin, direction: direction, limit: distance)
        let end = ray.origin + direction * hit.distance
        let ammo = ModelEntity(mesh: .generateSphere(radius: 0.025), materials: [UnlitMaterial(color: .systemGreen)])
        houseAnchor.addChild(ammo)
        let camera = arView.cameraTransform.matrix
        ammo.position = ray.origin + direction * 0.2 + simd_make_float3(camera.columns.0) * 0.08 - simd_make_float3(camera.columns.1) * 0.08
        ammo.move(to: Transform(translation: end), relativeTo: houseAnchor, duration: 0.18, timingFunction: .linear)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { ammo.scale = SIMD3(repeating: 2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ammo.removeFromParent() }
        return hit.id
    }

    /// Shared by live firing and geometry tests; `direction` is a normalized world-space ray.
    func shotTarget(from origin: SIMD3<Float>, direction: SIMD3<Float>, limit: Float = 12) -> (id: UUID?, distance: Float) {
        var distance = min(limit, obstacles.shotDistance(from: origin, direction: direction, limit: limit) ?? limit)
        var targetID: UUID?
        for (id, target) in paintTargets {
            guard target.model.isEnabled, ghostEntities[id]?.isEnabled == true else { continue }
            let transform = target.model.transformMatrix(relativeTo: nil)
            let localOrigin = simd_make_float3(transform.inverse * SIMD4(origin, 1))
            let localDirection = simd_normalize(simd_make_float3(transform.inverse * SIMD4(direction, 0)))
            guard let hit = target.surface.hit(origin: localOrigin, direction: localDirection) else { continue }
            let point = simd_make_float3(transform * SIMD4(localOrigin + localDirection * hit.distance, 1))
            let depth = simd_distance(origin, point)
            if depth < distance {
                distance = depth
                targetID = foundGhosts.contains(id) ? nil : id
            }
        }
        // Older USDZ/cutout ghosts retain their existing collision targeting.
        for hit in arView.scene.raycast(origin: origin, direction: direction, length: distance, query: .all) {
            var entity: Entity? = hit.entity
            while let current = entity {
                if let id = UUID(uuidString: current.name), ghostEntities[id] != nil {
                    if paintTargets[id] == nil, hit.distance < distance {
                        distance = hit.distance
                        targetID = foundGhosts.contains(id) ? nil : id
                    }
                    break
                }
                entity = current.parent
            }
        }
        return (targetID, distance)
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
            wallBoxes.append((wall.transform, SIMD2(wall.dimensions.x, wall.dimensions.y)))
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
