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
/// chameleon is stuck flat on a wall or lying on the floor (or furniture); it can change pose, be
/// tapped and dragged to another spot, pinched to resize, twisted to spin, or slid up, down, left
/// and right along its surface with a joystick. It never goes inside the scanned walls or furniture.
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
    /// How far the chameleon is spun on its surface, in degrees, for the turn slider.
    @Published private(set) var turn: Double = 0
    /// Stuck to a wall, rather than lying on the floor or furniture.
    @Published private(set) var onWall = false
    /// The joystick: x is right on screen, y up on screen, each -1...1.
    var joystick = SIMD2<Float>.zero

    static let heights: ClosedRange<Float> = 0.3...0.8

    private(set) var placement: GhostPlacement {
        didSet { if placement.onWall != onWall { onWall = placement.onWall } }
    }
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
    private let haptics = UIImpactFeedbackGenerator(style: .soft)
    private let gestures = BodyGestures()
    /// While dragging: from the finger to the body's middle on screen, so the body doesn't jump to the finger.
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
        onWall = placement.onWall
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
                if let start = locked(placement) { _ = apply(start) }
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
        guard let next = (1..<count).map({ (pose + $0) % count }).first(where: poseFits) else { return blocked() }
        switchPose(to: next)
    }

    func setPose(id: String) {
        guard isReady, let index = body.index(of: id), index != pose else { return }
        guard poseFits(index) else { return blocked() }
        switchPose(to: index)
    }

    private func poseFits(_ pose: Int) -> Bool { allowed(placement, pose: pose) }

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
        slide(elapsed)
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

    /// Slides the chameleon along its wall or floor exactly the way the joystick points on screen:
    /// it finds which way on the surface "right" and "up" on screen are, at the body.
    private func slide(_ elapsed: Float) {
        guard simd_length(joystick) > 0.05, let directions = screenDirections() else { return }
        let across = directions.right * joystick.x * 0.4 * elapsed
        let along = directions.up * joystick.y * 0.4 * elapsed
        // Straight there if it's clear, else sliding along whatever's in the way.
        if ![across + along, across, along].contains(where: { simd_length($0) > 1e-5 && move(to: placement.moved(by: $0)) }) {
            blocked()
        }
    }

    /// Which way on the chameleon's surface is right and up on screen, at its middle.
    private func screenDirections() -> (right: SIMD3<Float>, up: SIMD3<Float>)? {
        let view = ar.arView
        let middle = bodyBox(placement, pose: pose).center
        guard let screen = view.project(middle) else { return nil }
        // unproject lands on a plane's x-z plane, so its y axis is the surface normal.
        let normal = placement.facing
        let side = simd_normalize(simd_cross(normal, abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)))
        let plane = simd_float4x4(SIMD4(side, 0), SIMD4(normal, 0), SIMD4(simd_cross(side, normal), 0), SIMD4(middle, 1))
        let step: CGFloat = 30
        guard let here = view.unproject(screen, ontoPlane: plane),
              let right = view.unproject(CGPoint(x: screen.x + step, y: screen.y), ontoPlane: plane),
              let up = view.unproject(CGPoint(x: screen.x, y: screen.y - step), ontoPlane: plane),
              simd_length(right - here) > 1e-4, simd_length(up - here) > 1e-4 else { return nil }
        return (simd_normalize(right - here), simd_normalize(up - here))
    }

    // MARK: Moving it by hand

    /// Spins the chameleon on its surface to `degrees`.
    func setTurn(_ degrees: Double) {
        rotate(by: Float((degrees - Self.degrees(of: placement)) * .pi / 180))
    }

    /// Lays the chameleon flat on the real floor where it is: feet at the wall and head into the
    /// room if it was on a wall, else straight down from the furniture it was on.
    func stickToFloor() {
        guard isReady else { return }
        let size = bodySize(placement, pose: pose)
        var base = placement.origin, head = placement.up
        if placement.onWall {
            // The scan rounds off the corner where wall meets floor, so it lies a little way out.
            base += placement.facing * 0.08
            head = placement.facing
        }
        guard let floor = realFloor(under: base + head * (size.y / 2)) ?? ar.currentFrame.map(ar.floorHeight(for:)) else { return }
        base.y = floor
        let candidate = GhostPlacement(on: base, normal: [0, 1, 0], up: head, width: placement.width, height: placement.height)
        if !move(to: candidate) { blocked() }
    }

    /// Sticks the chameleon flat on the closest real wall around it, upright, with its feet just
    /// above whatever it was lying on (clear of the scan's rounded corner at the floor).
    func stickToWall() {
        guard isReady, !placement.onWall else { return }
        let size = bodySize(placement, pose: pose)
        let feet = placement.origin.y + 0.06
        var middle = placement.origin + placement.up * (size.y / 2)
        middle.y = feet + size.y / 2
        guard let wall = nearestRealWall(to: middle) ?? ar.obstacles.nearestWall(to: middle, within: 1.5) else {
            return flash("No wall nearby. Drag it onto one.")
        }
        let candidate = GhostPlacement(on: SIMD3(wall.point.x, feet, wall.point.z), normal: wall.normal, up: [0, 1, 0],
                                       width: placement.width, height: placement.height)
        if !move(to: candidate) { blocked() }
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
            guard isSelected || isOnBody(point), let middle = ar.arView.project(bodyBox(placement, pose: pose).center) else { return }
            grab = CGPoint(x: middle.x - point.x, y: middle.y - point.y)
            if !isSelected {
                isSelected = true
                updateRing()
            }
        case .changed:
            guard let grab, let spot = ar.surface(at: CGPoint(x: point.x + grab.x, y: point.y + grab.y)) else { return }
            // Keeps its spin on the same kind of surface; stands the default way on a new one.
            let sameKind = (spot.normal.y > 0.5) != placement.onWall
            var up = sameKind ? placement.up - spot.normal * simd_dot(placement.up, spot.normal) : .zero
            if simd_length(up) < 0.3 { up = ar.defaultUp(on: spot.normal, at: spot.point) }
            up = simd_normalize(up)
            let size = bodySize(placement, pose: pose)
            let candidate = GhostPlacement(on: spot.point - up * (size.y / 2), normal: spot.normal, up: up,
                                           width: placement.width, height: placement.height)
            if !move(to: candidate) { blocked() }
        default:
            grab = nil
        }
    }

    private func pinched(_ state: UIGestureRecognizer.State, scale: Float) {
        guard isReady, isSelected else { return }
        if state == .began { pinchStart = placement.height }
        guard state == .changed, pinchStart > 0 else { return }
        let height = min(max(pinchStart * scale, Self.heights.lowerBound), Self.heights.upperBound)
        if abs(height - placement.height) > 0.002, !apply(aroundMiddle(placement.resized(to: height))) { blocked() }
    }

    private func twisted(_ state: UIGestureRecognizer.State, rotation: Float) {
        guard isReady, isSelected else { return }
        if state == .began { lastTwist = 0 }
        guard state == .changed else { return }
        // Twisting clockwise on screen spins it clockwise as seen by the player.
        rotate(by: lastTwist - rotation)
        lastTwist = rotation
    }

    private func rotate(by angle: Float) {
        guard isReady, abs(angle) > 1e-4 else { return }
        if !apply(aroundMiddle(placement.turned(by: angle))) { blocked() }
    }

    /// `changed`, slid so the body's middle stays where it is now, so it spins and grows in place.
    private func aroundMiddle(_ changed: GhostPlacement) -> GhostPlacement {
        let middle = placement.origin + placement.up * (bodySize(placement, pose: pose).y / 2)
        return changed.moved(by: middle - changed.up * (bodySize(changed, pose: pose).y / 2) - changed.origin)
    }

    /// Moves the chameleon to `candidate` unless that puts it inside a wall or furniture, or off its surface.
    private func apply(_ candidate: GhostPlacement) -> Bool {
        guard allowed(candidate, pose: pose) else { return false }
        let restand = candidate.height != placement.height
        placement = candidate
        let degrees = Self.degrees(of: candidate)
        if abs(degrees - turn) > 0.5 { turn = degrees }
        if restand, let model {
            preview?.removeFromParent()
            preview = ar.addPreview(model, placement: candidate)
            updateRing()
        } else {
            preview?.transform = Transform(matrix: candidate.floorTransform)
        }
        return true
    }

    /// Moves the chameleon to `candidate`, pressed flat onto the real surface there, if it can go.
    private func move(to candidate: GhostPlacement) -> Bool {
        guard let locked = locked(candidate) else { return false }
        return apply(locked)
    }

    /// Whether the chameleon can be there in that pose. If it's already stuck in something, it may
    /// only move somewhere no worse, so it can always get back out but never go further in.
    private func allowed(_ candidate: GhostPlacement, pose: Int) -> Bool {
        guard ar.hasSceneMesh else { return fits(candidate, pose: pose) || !fits(placement, pose: self.pose) }
        let after = realOverlap(candidate, pose: pose)
        if after == 0 { return true }
        let before = realOverlap(placement, pose: self.pose)
        return before > 0 && after <= before
    }

    private func fits(_ placement: GhostPlacement, pose: Int) -> Bool {
        problem(with: placement, pose: pose) == nil
    }

    /// What's wrong with the chameleon being there, if anything: inside something in the live
    /// room scan or, without LiDAR, the house scan's walls and furniture or out of bounds.
    private func problem(with placement: GhostPlacement, pose: Int) -> String? {
        if ar.hasSceneMesh { return realOverlap(placement, pose: pose) > 0 ? "inside something" : nil }
        let obstacles = ar.obstacles
        let box = bodyBox(placement, pose: pose)
        if obstacles.blocks(box) { return "inside a wall or furniture" }
        let up = SIMD3<Float>(0, 1, 0), reach = box.radius(along: up)
        if let frame = ar.currentFrame, box.center.y - reach < ar.floorHeight(for: frame) - 0.03 { return "below the floor" }
        guard !obstacles.walls.isEmpty else { return nil }
        if let ceiling = obstacles.ceiling, box.center.y + reach > ceiling + 0.03 { return "above the ceiling" }
        if placement.onWall { return obstacles.nearestWall(to: box.center, within: 0.3) == nil ? "off the end of the wall" : nil }
        let height = placement.origin.y
        if let frame = ar.currentFrame, abs(height - ar.floorHeight(for: frame)) < 0.05 { return nil }
        guard let top = obstacles.furnitureTop(under: box.center, step: 0.06), abs(top - height) < 0.06 else { return "in the air" }
        return nil
    }

    // MARK: The real room

    /// The nearest real surface along a ray, from the phone's live LiDAR mesh of the room.
    private func realHit(from origin: SIMD3<Float>, along direction: SIMD3<Float>, length: Float) -> CollisionCastHit? {
        ar.arView.scene.raycast(origin: origin, direction: direction, length: length, query: .nearest,
                                mask: .sceneUnderstanding, relativeTo: nil).first
    }

    /// `candidate` pressed flat onto the real wall or floor behind it, or nil if nothing's there
    /// (off the end of a wall, or not scanned yet). On a floor it drops down off furniture.
    /// Without LiDAR it's left as it is.
    private func locked(_ candidate: GhostPlacement) -> GhostPlacement? {
        guard ar.hasSceneMesh else { return candidate }
        let normal = candidate.facing
        let middle = candidate.origin + candidate.up * (bodySize(candidate, pose: pose).y / 2)
        let reach: Float = candidate.onWall ? 0.4 : 2
        guard let hit = realHit(from: middle + normal * 0.08, along: -normal, length: reach + 0.08),
              abs(simd_dot(simd_normalize(hit.normal), normal)) > 0.7 else { return nil }
        return candidate.moved(by: normal * simd_dot(hit.position - middle, normal))
    }

    /// The real floor under `point`: the lowest upward-facing surface straight down.
    private func realFloor(under point: SIMD3<Float>) -> Float? {
        guard ar.hasSceneMesh else { return nil }
        return ar.arView.scene.raycast(origin: point + [0, 0.2, 0], direction: [0, -1, 0], length: 3, query: .all,
                                       mask: .sceneUnderstanding, relativeTo: nil)
            .filter { abs(simd_normalize($0.normal).y) > 0.7 }
            .map(\.position.y).min()
    }

    /// The closest real wall within 1.5 m of `point`, looking all the way around: where on it, level
    /// with `point`, and the way out of it.
    private func nearestRealWall(to point: SIMD3<Float>) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard ar.hasSceneMesh else { return nil }
        var best: (point: SIMD3<Float>, normal: SIMD3<Float>, distance: Float)?
        for step in 0..<24 {
            let angle = Float(step) * .pi / 12
            let direction = SIMD3<Float>(sin(angle), 0, cos(angle))
            guard let hit = realHit(from: point, along: direction, length: 1.5), hit.distance < best?.distance ?? .infinity else { continue }
            var normal = simd_normalize(hit.normal)
            normal.y = 0
            guard simd_length(normal) > 0.95 else { continue }
            normal = simd_normalize(normal)
            if simd_dot(normal, direction) > 0 { normal = -normal }
            best = (SIMD3(hit.position.x, point.y, hit.position.z), normal, hit.distance)
        }
        return best.map { ($0.point, $0.normal) }
    }

    /// How many edges and diagonals of the body's box pass through the real room. 0 means it's clear.
    private func realOverlap(_ placement: GhostPlacement, pose: Int) -> Int {
        guard ar.hasSceneMesh else { return 0 }
        var box = bodyBox(placement, pose: pose)
        // Stays clear of the surface it's stuck to, which the scan shows a little bumpy.
        let lift: Float = 0.02
        box.halfSize.z = max(box.halfSize.z - lift / 2, 0.01)
        box.transform.columns.3 += SIMD4(placement.facing * (lift / 2), 0)
        let axes = (0..<3).map { box.axis($0) * box.halfSize[$0] }
        let corners = (0..<8).map { (i: Int) -> SIMD3<Float> in
            box.center + axes[0] * (i & 1 == 0 ? -1 : 1) + axes[1] * (i & 2 == 0 ? -1 : 1) + axes[2] * (i & 4 == 0 ? -1 : 1)
        }
        var segments = [(0, 7), (1, 6), (2, 5), (3, 4)]
        for i in 0..<8 { for bit in [1, 2, 4] where i & bit == 0 { segments.append((i, i | bit)) } }
        let scene = ar.arView.scene
        // Both ways, since the mesh may only be hit from its front.
        return segments.filter { a, b in
            !scene.raycast(from: corners[a], to: corners[b], query: .any, mask: .sceneUnderstanding, relativeTo: nil).isEmpty
                || !scene.raycast(from: corners[b], to: corners[a], query: .any, mask: .sceneUnderstanding, relativeTo: nil).isEmpty
        }.count
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

    /// The body's size in metres in this pose: x across, y feet to head, z out of the surface.
    private func bodySize(_ placement: GhostPlacement, pose: Int) -> SIMD3<Float> {
        let bounds = body.bounds[pose]
        // The 3D editor normalizes every character to 1.75 m standing.
        return (bounds.max - bounds.min) * (placement.height / 1.75)
    }

    /// The space the body takes up where ARGameController puts it, a little smaller so touching
    /// isn't overlapping.
    private func bodyBox(_ placement: GhostPlacement, pose: Int) -> RoomObstacles.Box {
        let size = bodySize(placement, pose: pose)
        var transform = placement.floorTransform
        transform.columns.3 = placement.floorTransform * SIMD4(0, size.y / 2, 0.015 + size.z / 2, 1)
        return RoomObstacles.Box(transform: transform, halfSize: simd_max(size / 2 - 0.02, SIMD3(repeating: 0.01)))
    }

    /// A lime outline on the surface behind the chameleon while it's selected.
    private func updateRing() {
        ring?.removeFromParent()
        ring = nil
        guard isSelected, let preview else { return }
        let size = bodySize(placement, pose: pose)
        let width = size.x + 0.12, height = size.y + 0.12
        var material = UnlitMaterial(color: UIColor(RallyStyle.lime))
        material.blending = .transparent(opacity: 0.6)
        let halo = ModelEntity(mesh: .generatePlane(width: width, height: height, cornerRadius: min(width, height) / 2),
                               materials: [material])
        // In front of the invisible wall that hides things behind it.
        halo.position = SIMD3(0, size.y / 2, 0.012)
        preview.addChild(halo)
        ring = halo
    }

    /// How far the body is spun from standing straight up on a wall, or from head-away on the floor.
    private static func degrees(of placement: GhostPlacement) -> Double {
        let normal = placement.facing
        var reference = placement.onWall ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, -1)
        reference = simd_normalize(reference - normal * simd_dot(reference, normal))
        let angle = atan2(simd_dot(simd_cross(reference, placement.up), normal), simd_dot(reference, placement.up))
        return Double(angle * 180 / .pi)
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
