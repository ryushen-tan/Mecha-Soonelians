import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

/// The chameleon's surface in its own coordinates, for finding where spray lands and which texel
/// that is. Triangles are two-sided because the body's winding isn't consistent.
struct BodySurface {
    struct Hit {
        let distance: Float
        let uv: SIMD2<Float>
        /// Texels per model-space unit where it landed, for sizing the spray dot.
        let density: Float
        /// 1 when the ray hit the surface head-on, near 0 when it grazed it.
        let facing: Float
    }

    /// A bounding-volume node. A leaf covers `order[start..<start + count]`; an inner node
    /// (count 0) has its left child right after it and its right child at `right`.
    private struct Node {
        var min: SIMD3<Float>
        var max: SIMD3<Float>
        var start: Int32
        var count: Int32
        var right: Int32
    }

    private let positions: [SIMD3<Float>]
    private let uvs: [SIMD2<Float>]
    private let triangles: [SIMD3<Int32>]
    private var density: [Float] = []
    private var normals: [SIMD3<Float>] = []
    private var order: [Int32] = []
    private var nodes: [Node] = []

    struct Mesh {
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var triangles: [SIMD3<Int32>] = []
    }

    /// Every textured triangle under `root`, in `root`'s own coordinates.
    @MainActor static func mesh(of root: Entity) -> Mesh {
        var mesh = Mesh()
        func visit(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                let toRoot = entity.transformMatrix(relativeTo: root)
                let contents = model.mesh.contents
                for instance in contents.instances {
                    guard let source = contents.models[instance.model] else { continue }
                    let transform = toRoot * instance.transform
                    for part in source.parts {
                        guard let uvs = part.textureCoordinates?.elements, let indices = part.triangleIndices?.elements else { continue }
                        let positions = part.positions.elements
                        guard uvs.count == positions.count else { continue }
                        let base = Int32(mesh.positions.count)
                        mesh.positions += positions.map { simd_make_float3(transform * SIMD4($0, 1)) }
                        mesh.uvs += uvs
                        for i in stride(from: 0, to: indices.count - 2, by: 3) {
                            mesh.triangles.append(SIMD3(base + Int32(indices[i]), base + Int32(indices[i + 1]), base + Int32(indices[i + 2])))
                        }
                    }
                }
            }
            entity.children.forEach(visit)
        }
        visit(root)
        return mesh
    }

    init(_ mesh: Mesh, textureSize: Int) {
        positions = mesh.positions
        uvs = mesh.uvs
        triangles = mesh.triangles
        let pixels = Float(textureSize)
        density = triangles.map { t in
            let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
            let area = simd_length(simd_cross(b - a, c - a))
            let ua = uvs[Int(t.x)], ub = uvs[Int(t.y)], uc = uvs[Int(t.z)]
            let uvArea = abs((ub.x - ua.x) * (uc.y - ua.y) - (uc.x - ua.x) * (ub.y - ua.y)) * pixels * pixels
            return (uvArea / max(area, 1e-12)).squareRoot()
        }
        normals = triangles.map { t in
            let a = positions[Int(t.x)]
            let normal = simd_cross(positions[Int(t.y)] - a, positions[Int(t.z)] - a)
            return simd_length(normal) > 0 ? simd_normalize(normal) : SIMD3(0, 0, 1)
        }
        order = (0..<Int32(triangles.count)).map { $0 }
        guard !triangles.isEmpty else { return }
        let centroids = triangles.map { (positions[Int($0.x)] + positions[Int($0.y)] + positions[Int($0.z)]) / 3 }
        build(0, triangles.count, centroids)
    }

    @discardableResult
    private mutating func build(_ start: Int, _ end: Int, _ centroids: [SIMD3<Float>]) -> Int {
        var low = SIMD3<Float>(repeating: .infinity), high = -low
        var centerLow = low, centerHigh = high
        for i in start..<end {
            let t = triangles[Int(order[i])]
            for corner in [t.x, t.y, t.z] {
                low = simd_min(low, positions[Int(corner)])
                high = simd_max(high, positions[Int(corner)])
            }
            centerLow = simd_min(centerLow, centroids[Int(order[i])])
            centerHigh = simd_max(centerHigh, centroids[Int(order[i])])
        }
        let index = nodes.count
        nodes.append(Node(min: low, max: high, start: Int32(start), count: 0, right: 0))
        guard end - start > 4 else {
            nodes[index].count = Int32(end - start)
            return index
        }
        // Split at the median along the widest axis.
        let extent = centerHigh - centerLow
        let axis = extent.x > extent.y ? (extent.x > extent.z ? 0 : 2) : (extent.y > extent.z ? 1 : 2)
        order[start..<end].sort { centroids[Int($0)][axis] < centroids[Int($1)][axis] }
        let middle = (start + end) / 2
        build(start, middle, centroids)
        nodes[index].right = Int32(build(middle, end, centroids))
        return index
    }

    /// Texels just outside the painted surface paired with the surface texel each copies, so seams
    /// don't show the white gaps between pieces of the texture. Marks the texels the triangles
    /// cover, then spreads outward a few texels.
    static func gutter(of mesh: Mesh, size: Int) -> [SIMD2<Int32>] {
        let uvs = mesh.uvs, triangles = mesh.triangles
        var source = [Int32](repeating: -1, count: size * size)
        let scale = Float(size)
        for t in triangles {
            let a = SIMD2(uvs[Int(t.x)].x, 1 - uvs[Int(t.x)].y) * scale
            let b = SIMD2(uvs[Int(t.y)].x, 1 - uvs[Int(t.y)].y) * scale
            let c = SIMD2(uvs[Int(t.z)].x, 1 - uvs[Int(t.z)].y) * scale
            let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            guard abs(area) > 1e-9 else { continue }
            let low = simd_max(simd_min(simd_min(a, b), c).rounded(.down), SIMD2(repeating: 0))
            let high = simd_min(simd_max(simd_max(a, b), c).rounded(.up), SIMD2(repeating: scale - 1))
            guard low.x <= high.x, low.y <= high.y else { continue }
            for y in Int(low.y)...Int(high.y) {
                for x in Int(low.x)...Int(high.x) {
                    let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    let w0 = ((b.x - p.x) * (c.y - p.y) - (c.x - p.x) * (b.y - p.y)) / area
                    let w1 = ((c.x - p.x) * (a.y - p.y) - (a.x - p.x) * (c.y - p.y)) / area
                    let w2 = 1 - w0 - w1
                    // A little slack so texels on a triangle's edge count as covered.
                    if w0 >= -0.02, w1 >= -0.02, w2 >= -0.02 { source[y * size + x] = Int32(y * size + x) }
                }
            }
        }
        var frontier = (0..<Int32(source.count)).filter { source[Int($0)] >= 0 }
        var pairs: [SIMD2<Int32>] = []
        for _ in 0..<6 {
            var next: [Int32] = []
            for texel in frontier {
                let x = Int(texel) % size, y = Int(texel) / size
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < size && ny < size {
                    let neighbor = ny * size + nx
                    guard source[neighbor] < 0 else { continue }
                    source[neighbor] = source[Int(texel)]
                    pairs.append(SIMD2(Int32(neighbor), source[Int(texel)]))
                    next.append(Int32(neighbor))
                }
            }
            frontier = next
        }
        return pairs
    }

    /// The nearest point the ray hits, if any.
    func hit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Hit? {
        guard !nodes.isEmpty else { return nil }
        let inverse = 1 / direction
        var best = Float.infinity
        var found: (triangle: Int, u: Float, v: Float)?
        var stack: [Int32] = [0]
        stack.reserveCapacity(64)
        while let index = stack.popLast() {
            let node = nodes[Int(index)]
            let near = (node.min - origin) * inverse, far = (node.max - origin) * inverse
            let enter = simd_reduce_max(simd_min(near, far)), exit = simd_reduce_min(simd_max(near, far))
            guard exit >= max(enter, 0), enter < best else { continue }
            if node.count == 0 {
                stack.append(index + 1)
                stack.append(node.right)
                continue
            }
            for i in Int(node.start)..<Int(node.start + node.count) {
                let triangle = Int(order[i]), t = triangles[triangle]
                let a = positions[Int(t.x)]
                let edge1 = positions[Int(t.y)] - a, edge2 = positions[Int(t.z)] - a
                let p = simd_cross(direction, edge2)
                let determinant = simd_dot(edge1, p)
                guard abs(determinant) > 1e-12 else { continue }
                let s = origin - a
                let u = simd_dot(s, p) / determinant
                guard u >= 0, u <= 1 else { continue }
                let q = simd_cross(s, edge1)
                let v = simd_dot(direction, q) / determinant
                guard v >= 0, u + v <= 1 else { continue }
                let distance = simd_dot(edge2, q) / determinant
                if distance > 1e-5, distance < best {
                    best = distance
                    found = (triangle, u, v)
                }
            }
        }
        guard let found else { return nil }
        let t = triangles[found.triangle]
        let uv = uvs[Int(t.x)] * (1 - found.u - found.v) + uvs[Int(t.y)] * found.u + uvs[Int(t.z)] * found.v
        return Hit(distance: best, uv: uv, density: density[found.triangle],
                   facing: abs(simd_dot(simd_normalize(direction), normals[found.triangle])))
    }
}

/// The chameleon's paint, in its texture's layout. Starts white, like every Meccha player.
final class PaintCanvas {
    static let size = 1024
    private(set) var pixels: [UInt8]
    private var history: [[UInt8]] = []
    /// See `BodySurface.gutter`.
    var gutter: [SIMD2<Int32>] = []

    init() {
        pixels = [UInt8](repeating: 255, count: Self.size * Self.size * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 244
            pixels[i + 1] = 244
            pixels[i + 2] = 241
        }
    }

    func restore(_ image: CGImage) {
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: Self.size, height: Self.size,
                bitsPerComponent: 8, bytesPerRow: Self.size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        }
    }

    var canUndo: Bool { !history.isEmpty }

    /// Call when a spray stroke starts, so it can be undone.
    func beginStroke() {
        history.append(pixels)
        if history.count > 8 { history.removeFirst() }
    }

    func undo() {
        if let last = history.popLast() { pixels = last }
    }

    /// A soft round dot. `uv` has v going up, like the texture coordinates; `radius` is in texels.
    func splat(at uv: SIMD2<Float>, radius: Float, color: SIMD3<Float>, strength: Float) {
        let size = Self.size
        let cx = uv.x * Float(size), cy = (1 - uv.y) * Float(size)
        let minX = max(0, Int(cx - radius)), maxX = min(size - 1, Int(cx + radius))
        let minY = max(0, Int(cy - radius)), maxY = min(size - 1, Int(cy + radius))
        guard minX <= maxX, minY <= maxY else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in minY...maxY {
                let dy = Float(y) + 0.5 - cy
                for x in minX...maxX {
                    let dx = Float(x) + 0.5 - cx
                    let falloff = 1 - (dx * dx + dy * dy) / (radius * radius)
                    guard falloff > 0 else { continue }
                    let amount = strength * falloff
                    let i = (y * size + x) * 4
                    for channel in 0..<3 {
                        let old = Float(buffer[i + channel])
                        buffer[i + channel] = UInt8(max(0, min(255, (old + (color[channel] - old) * amount).rounded())))
                    }
                }
            }
        }
    }

    func image() -> CGImage? {
        pixels.withUnsafeMutableBufferPointer { buffer in
            for pair in gutter {
                let to = Int(pair.x) * 4, from = Int(pair.y) * 4
                buffer[to] = buffer[from]
                buffer[to + 1] = buffer[from + 1]
                buffer[to + 2] = buffer[from + 2]
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: Self.size, height: Self.size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.size * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func jpeg() -> Data? {
        image().flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.85) }
    }
}

/// Spray-painting the hider's chameleon where it stands in AR: aim the + at the wall to pick a
/// color, then hold to spray where the + points. Closer sprays finer, farther sprays wider. The
/// chameleon can also change pose, be tapped and dragged onto the floor, a wall or furniture,
/// pinched to resize and twisted to turn, or walked with a joystick. It never goes inside the
/// scanned walls or furniture.
@MainActor
final class SprayPainter: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var aimingAtBody = false
    @Published private(set) var color = UIColor(white: 0.5, alpha: 1)
    @Published private(set) var hasPickedColor = false
    @Published private(set) var canUndo = false
    @Published private(set) var pose = 0
    /// 0 is a fine line, 1 a wide cloud.
    @Published var spread: Float = 0.35
    @Published var error: String?
    @Published var isSpraying = false {
        didSet {
            guard isSpraying != oldValue else { return }
            lastDistance = nil
            if isSpraying {
                canvas.beginStroke()
                canUndo = true
            }
        }
    }
    /// Tapped, so pinching resizes it and twisting turns it.
    @Published private(set) var isSelected = false
    /// Why the last move didn't happen, for a moment.
    @Published private(set) var notice: String?
    /// Which way the chameleon faces, in degrees, for the turn slider.
    @Published private(set) var turn: Double = 0
    /// The joystick: x to the player's right, y away from the player, each -1...1.
    var joystick = SIMD2<Float>.zero

    static let heights: ClosedRange<Float> = 0.35...1.0

    private(set) var placement: GhostPlacement
    let canvas = PaintCanvas()
    private let ar: ARGameController
    private let body: ChameleonBody
    private var preview: Entity?
    private var model: Entity?
    private var surface: BodySurface?
    private var texture: TextureResource?
    private var updates: Cancellable?
    private var dirty = false
    private var lastTick: TimeInterval?
    private var lastUpload: TimeInterval = 0
    private var lastBuzz: TimeInterval = 0
    /// How far away the body was while spraying, so the edge of the spray still lands when the + slips off it.
    private var lastDistance: Float?
    /// Where in its hop the chameleon is while it's being walked, and how high it is.
    private var hopPhase: Float = 0
    private var hop: Float = 0
    private let haptics = UIImpactFeedbackGenerator(style: .soft)
    private let gestures = BodyGestures()
    /// While dragging: from the finger to the feet on screen, so the body doesn't jump to the finger.
    private var grab: CGPoint?
    private var pinchStart: Float = 0
    private var lastTwist: Float = 0
    private var lastBlocked: TimeInterval = 0
    private var ring: Entity?

    init?(ar: ARGameController, placement: GhostPlacement) {
        guard let body = ChameleonBody.personal else { return nil }
        self.ar = ar
        self.placement = placement
        self.body = body
        if let texture = body.initialTexture { canvas.restore(texture) }
        turn = Self.degrees(of: placement)
        guard !ar.obstacles.blocks(bodyBox(placement, pose: 0)) else { return nil }
    }

    var poseName: String { body.poses[pose].name }
    var poseIcon: String { body.poses[pose].icon }
    var poseID: String { body.poses[pose].id }
    func exportBody() throws -> Data { try body.exportedPose(pose) }
    /// Every pose, eight to a page, for the pose wheel.
    var posePages: [[CharacterPoseChoice]] {
        let choices = body.poses.map { CharacterPoseChoice(id: $0.id, name: $0.name, icon: $0.icon) }
        return stride(from: 0, to: choices.count, by: 8).map { Array(choices[$0..<min($0 + 8, choices.count)]) }
    }

    func load() {
        Task {
            do {
                let mesh = body.mesh(pose)
                let gutter = await Task.detached { BodySurface.gutter(of: mesh, size: PaintCanvas.size) }.value
                canvas.gutter = gutter
                guard let image = canvas.image() else { throw CocoaError(.fileReadCorruptFile) }
                texture = try await TextureResource(image: image, options: .init(semantic: .color))
                try await show(pose: pose)
                updates = ar.arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                gestures.onTap = { [weak self] in self?.tapped(at: $0) }
                gestures.onDrag = { [weak self] in self?.dragged($0, at: $1) }
                gestures.onPinch = { [weak self] in self?.pinched($0, scale: $1) }
                gestures.onTwist = { [weak self] in self?.twisted($0, rotation: $1) }
                gestures.install(on: ar.arView)
                isReady = true
            } catch {
                self.error = "Couldn't show your chameleon here. Cancel and try again."
            }
        }
    }

    /// Switches to the next pose that fits where the chameleon is. The paint stays where it was on the body.
    func nextPose() {
        guard isReady else { return }
        let count = body.poses.count
        guard let next = (1..<count).map({ (pose + $0) % count }).first(where: fits) else { return blocked() }
        switchPose(to: next)
    }

    func setPose(id: String) {
        guard isReady, let index = body.index(of: id), index != pose else { return }
        guard fits(pose: index) else { return blocked() }
        switchPose(to: index)
    }

    private func fits(pose: Int) -> Bool { allowed(placement, pose: pose) }

    private func switchPose(to index: Int) {
        pose = index
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            try? await show(pose: index)
        }
    }

    private func show(pose: Int) async throws {
        guard let texture else { return }
        let mesh = body.mesh(pose)
        let entity = try body.entity(pose, paint: texture)
        let surface = await Task.detached { BodySurface(mesh, textureSize: PaintCanvas.size) }.value
        // Another tap may have moved on to a later pose meanwhile.
        guard pose == self.pose else { return }
        preview?.removeFromParent()
        self.surface = surface
        model = entity
        preview = ar.addPreview(entity, placement: placement)
        updateRing()
    }

    func remove() {
        updates?.cancel()
        updates = nil
        gestures.uninstall()
        preview?.removeFromParent()
        preview = nil
        isSpraying = false
    }

    func undo() {
        canvas.undo()
        canUndo = canvas.canUndo
        upload()
    }

    /// Picks up the color of whatever real thing is under the +.
    func pickColor() {
        guard let frame = ar.currentFrame,
              let picked = Self.centerColor(of: frame, viewSize: ar.arView.bounds.size) else { return }
        color = picked
        hasPickedColor = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// The paint, ready to send with the ghost.
    func paintJPEG() -> Data? { canvas.jpeg() }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = Float(min(now - (lastTick ?? now), 0.1))
        lastTick = now
        walk(elapsed)
        guard let model, let surface else { return }
        let view = ar.arView
        guard let ray = view.ray(through: CGPoint(x: view.bounds.midX, y: view.bounds.midY)) else { return }
        let toModel = model.transformMatrix(relativeTo: nil).inverse
        let origin = simd_make_float3(toModel * SIMD4(ray.origin, 1))
        let forward = simd_normalize(simd_make_float3(toModel * SIMD4(ray.direction, 0)))
        let center = surface.hit(origin: origin, direction: forward)
        if (center != nil) != aimingAtBody { aimingAtBody = center != nil }

        if isSpraying, let distance = center?.distance ?? lastDistance {
            lastDistance = distance
            if spray(on: surface, from: origin, along: forward, distance: distance), now - lastBuzz > 0.08 {
                haptics.impactOccurred(intensity: 0.5)
                lastBuzz = now
            }
        }
        if dirty, now - lastUpload > 1.0 / 15 {
            upload()
            lastUpload = now
        }
    }

    /// Walks the chameleon from the joystick, hopping as it goes.
    private func walk(_ elapsed: Float) {
        guard let preview else { return }
        let moving = simd_length(joystick) > 0.05
        if moving, let frame = ar.currentFrame {
            // Joystick directions follow where the phone is facing, flat along the floor.
            let camera = frame.camera.transform
            var ahead = -simd_make_float3(camera.columns.2), right = simd_make_float3(camera.columns.0)
            ahead.y = 0
            right.y = 0
            if simd_length(ahead) > 0.01, simd_length(right) > 0.01 {
                let step = (simd_normalize(right) * joystick.x + simd_normalize(ahead) * joystick.y) * 0.6 * elapsed
                let floor = ar.floorHeight(for: frame)
                // Straight ahead if it's clear, else sliding along whatever's in the way.
                let tries = [step, SIMD3(step.x, 0, 0), SIMD3(0, 0, step.z)].filter { simd_length($0) > 1e-5 }
                if !tries.contains(where: { apply(supported(placement.moved(by: $0, turn: 0), floor: floor)) }) {
                    blocked()
                }
            }
        }
        if moving {
            hopPhase += elapsed * 12
            hop = abs(sin(hopPhase)) * placement.height * 0.12
        } else {
            hopPhase = 0
            hop *= 0.7
        }
        var transform = placement.floorTransform
        transform.columns.3.y += hop
        preview.transform = Transform(matrix: transform)
    }

    /// Keeps a walked chameleon on what's under it: up onto low furniture, and down to the floor
    /// when it walks off the furniture it was on.
    private func supported(_ candidate: GhostPlacement, floor: Float) -> GhostPlacement {
        let obstacles = ar.obstacles
        if let top = obstacles.furnitureTop(under: candidate.origin, step: 0.1) { return candidate.raised(to: top) }
        if obstacles.furnitureTop(under: placement.origin, step: 0.1) != nil { return candidate.raised(to: floor) }
        return candidate
    }

    // MARK: Moving it by hand

    /// Turns the chameleon to face `degrees` (0 is the house's +Z).
    func setTurn(_ degrees: Double) {
        rotate(by: Float((degrees - Self.degrees(of: placement)) * .pi / 180))
    }

    /// Stands the chameleon on the floor right where it is, stepping off the wall or furniture.
    func toFloor() {
        guard isReady, let frame = ar.currentFrame else { return }
        if !apply(freeStanding(placement).raised(to: ar.floorHeight(for: frame))) { blocked() }
    }

    /// Puts the chameleon's back on the closest scanned wall.
    func againstWall() {
        guard isReady, let frame = ar.currentFrame else { return }
        guard let wall = ar.obstacles.nearestWall(to: bodyBox(placement, pose: pose).center, within: 1.5) else {
            return flash("No scanned wall nearby. Drag it closer to one.")
        }
        let origin = SIMD3(wall.point.x, ar.floorHeight(for: frame), wall.point.z)
        let candidate = GhostPlacement(origin: origin, facing: wall.normal, onWall: true, width: placement.width, height: placement.height)
        if !apply(candidate) { blocked() }
    }

    private func tapped(at point: CGPoint) {
        guard isReady else { return }
        let selected = isOnBody(point) && !isSelected
        guard selected != isSelected else { return }
        isSelected = selected
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateRing()
    }

    private func dragged(_ state: UIGestureRecognizer.State, at point: CGPoint) {
        guard isReady else { return }
        switch state {
        case .began:
            guard isSelected || isOnBody(point), let feet = ar.arView.project(placement.origin) else { return }
            grab = CGPoint(x: feet.x - point.x, y: feet.y - point.y)
            if !isSelected {
                isSelected = true
                updateRing()
            }
        case .changed:
            guard let grab else { return }
            let target = CGPoint(x: point.x + grab.x, y: point.y + grab.y)
            guard let moved = ar.chameleonPlacement(at: target, height: placement.height, facing: placement.facing) else { return }
            if !apply(moved) { blocked() }
        default:
            grab = nil
        }
    }

    private func pinched(_ state: UIGestureRecognizer.State, scale: Float) {
        guard isReady, isSelected else { return }
        if state == .began { pinchStart = placement.height }
        guard state == .changed, pinchStart > 0 else { return }
        let height = min(max(pinchStart * scale, Self.heights.lowerBound), Self.heights.upperBound)
        if abs(height - placement.height) > 0.002, !apply(placement.resized(to: height)) { blocked() }
    }

    private func twisted(_ state: UIGestureRecognizer.State, rotation: Float) {
        guard isReady, isSelected else { return }
        if state == .began { lastTwist = 0 }
        guard state == .changed else { return }
        // Twisting clockwise on screen turns it clockwise seen from above.
        rotate(by: lastTwist - rotation)
        lastTwist = rotation
    }

    private func rotate(by angle: Float) {
        guard isReady, abs(angle) > 1e-4 else { return }
        if !apply(freeStanding(placement).moved(by: .zero, turn: angle)) { blocked() }
    }

    /// The same spot, but standing on its own: off the wall, where its body already was.
    private func freeStanding(_ placement: GhostPlacement) -> GhostPlacement {
        guard placement.flushBack else { return placement }
        let depth = bodySize(placement, pose: pose).z
        return GhostPlacement(origin: placement.origin + placement.facing * (0.015 + depth / 2), facing: placement.facing,
                              onWall: false, width: placement.width, height: placement.height)
    }

    /// Moves the chameleon to `candidate` unless that puts it inside a wall or furniture.
    private func apply(_ candidate: GhostPlacement) -> Bool {
        guard allowed(candidate, pose: pose) else { return false }
        let restand = candidate.height != placement.height || candidate.flushBack != placement.flushBack
        placement = candidate
        let degrees = Self.degrees(of: candidate)
        if abs(degrees - turn) > 0.5 { turn = degrees }
        if restand, let model {
            preview?.removeFromParent()
            preview = ar.addPreview(model, placement: candidate)
            updateRing()
        }
        return true
    }

    /// Whether the chameleon can be there in that pose. Anything goes while it's already stuck
    /// inside something, so it can always be moved back out.
    private func allowed(_ candidate: GhostPlacement, pose: Int) -> Bool {
        let obstacles = ar.obstacles
        return !obstacles.blocks(bodyBox(candidate, pose: pose)) || obstacles.blocks(bodyBox(placement, pose: self.pose))
    }

    private func blocked() {
        let now = CACurrentMediaTime()
        guard now - lastBlocked > 0.5 else { return }
        lastBlocked = now
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        flash("Something's in the way.")
    }

    private func flash(_ message: String) {
        notice = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.notice == message { self?.notice = nil }
        }
    }

    private func isOnBody(_ point: CGPoint) -> Bool {
        var entity = ar.arView.entity(at: point)
        while let current = entity {
            if current === preview { return true }
            entity = current.parent
        }
        return false
    }

    /// The body's size in metres in this pose.
    private func bodySize(_ placement: GhostPlacement, pose: Int) -> SIMD3<Float> {
        let bounds = body.bounds[pose]
        // The 3D editor normalizes every character to 1.75 m standing.
        return (bounds.max - bounds.min) * (placement.height / 1.75)
    }

    /// The space the body takes up, where ARGameController stands it: a little smaller, so touching
    /// isn't overlapping, and lifted off whatever it stands on.
    private func bodyBox(_ placement: GhostPlacement, pose: Int) -> RoomObstacles.Box {
        let size = bodySize(placement, pose: pose)
        let center = SIMD3<Float>(0, size.y / 2 + 0.015, placement.flushBack ? 0.015 + size.z / 2 : 0)
        var transform = placement.floorTransform
        transform.columns.3 = placement.floorTransform * SIMD4(center, 1)
        return RoomObstacles.Box(transform: transform, halfSize: simd_max(size / 2 - SIMD3(0.02, 0.035, 0.02), SIMD3(repeating: 0.01)))
    }

    /// A lime disc under the chameleon while it's selected.
    private func updateRing() {
        ring?.removeFromParent()
        ring = nil
        guard isSelected, let preview else { return }
        let size = bodySize(placement, pose: pose)
        let radius = max(size.x, size.z) / 2 + 0.06
        var material = UnlitMaterial(color: UIColor(RallyStyle.lime))
        material.blending = .transparent(opacity: 0.6)
        let disc = ModelEntity(mesh: .generatePlane(width: radius * 2, depth: radius * 2, cornerRadius: radius), materials: [material])
        disc.position = SIMD3(0, 0.004, placement.flushBack ? 0.015 + size.z / 2 : 0)
        preview.addChild(disc)
        ring = disc
    }

    private static func degrees(of placement: GhostPlacement) -> Double {
        Double(atan2(placement.facing.x, placement.facing.z) * 180 / .pi)
    }

    /// Scatters drops through a cone around the + like a spray can. Returns whether any landed.
    private func spray(on surface: BodySurface, from origin: SIMD3<Float>, along forward: SIMD3<Float>, distance: Float) -> Bool {
        let drops = 48
        let spreadAngle = (0.5 + spread * 7.5) * .pi / 180
        let reach = tan(spreadAngle)
        // Each drop covers its share of the cone's circle where it meets the body.
        let spacing = distance * reach * (Float.pi / Float(drops)).squareRoot()
        let side = simd_normalize(simd_cross(forward, abs(forward.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
        let up = simd_cross(side, forward)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        let rgb = SIMD3(Float(red), Float(green), Float(blue)) * 255

        var landed = false
        for _ in 0..<drops {
            let angle = Float.random(in: 0..<(2 * .pi))
            let offset = Float.random(in: 0...1).squareRoot() * reach
            let direction = simd_normalize(forward + side * (cos(angle) * offset) + up * (sin(angle) * offset))
            guard let hit = surface.hit(origin: origin, direction: direction) else { continue }
            // Spray spreads out on a slanted surface.
            let radius = min(max(spacing * 1.2 * hit.density / max(hit.facing, 0.3), 1.5), 28)
            canvas.splat(at: hit.uv, radius: radius, color: rgb, strength: 0.3)
            landed = true
        }
        if landed { dirty = true }
        return landed
    }

    private func upload() {
        dirty = false
        guard let texture, let image = canvas.image() else { return }
        try? texture.replace(withImage: image, options: .init(semantic: .color))
    }

    /// The average color of the camera image under the middle of the screen.
    nonisolated static func centerColor(of frame: ARFrame, viewSize: CGSize) -> UIColor? {
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 2, viewSize.width > 0 else { return nil }
        let toView = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        let point = CGPoint(x: 0.5, y: 0.5).applying(toView.inverted())
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self), chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        let centerX = Int(point.x * CGFloat(width)), centerY = Int(point.y * CGFloat(height))

        // Full-range BT.601, which is what ARKit's camera images use.
        var sum = SIMD3<Float>(repeating: 0)
        var count: Float = 0
        for y in stride(from: centerY - 10, through: centerY + 10, by: 2) where y >= 0 && y < height {
            for x in stride(from: centerX - 10, through: centerX + 10, by: 2) where x >= 0 && x < width {
                let brightness = Float(luma[y * lumaRow + x])
                let c = (y / 2) * chromaRow + (x / 2) * 2
                let blueDiff = Float(chroma[c]) - 128, redDiff = Float(chroma[c + 1]) - 128
                sum += SIMD3(brightness + 1.402 * redDiff,
                             brightness - 0.344136 * blueDiff - 0.714136 * redDiff,
                             brightness + 1.772 * blueDiff)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let rgb = simd_clamp(sum / count / 255, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }
}

/// Touches on the AR view while hiding: tap, one-finger drag, pinch and twist, all at once.
@MainActor
private final class BodyGestures: NSObject, UIGestureRecognizerDelegate {
    var onTap: (CGPoint) -> Void = { _ in }
    var onDrag: (UIGestureRecognizer.State, CGPoint) -> Void = { _, _ in }
    var onPinch: (UIGestureRecognizer.State, Float) -> Void = { _, _ in }
    var onTwist: (UIGestureRecognizer.State, Float) -> Void = { _, _ in }
    private var recognizers: [UIGestureRecognizer] = []

    func install(on view: UIView) {
        uninstall()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        recognizers = [
            UITapGestureRecognizer(target: self, action: #selector(tapped)),
            pan,
            UIPinchGestureRecognizer(target: self, action: #selector(pinched)),
            UIRotationGestureRecognizer(target: self, action: #selector(twisted)),
        ]
        for recognizer in recognizers {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    func uninstall() {
        for recognizer in recognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizers = []
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) { onTap(gesture.location(in: gesture.view)) }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) { onDrag(gesture.state, gesture.location(in: gesture.view)) }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) { onPinch(gesture.state, Float(gesture.scale)) }
    @objc private func twisted(_ gesture: UIRotationGestureRecognizer) { onTwist(gesture.state, Float(gesture.rotation)) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
