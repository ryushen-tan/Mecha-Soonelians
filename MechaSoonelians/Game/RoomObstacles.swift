import RoomPlan
import simd

/// The scanned walls and furniture as boxes, so a chameleon can't be put inside them.
struct RoomObstacles {
    /// A box in house coordinates: `transform` is its center and axes, `halfSize` half its size along them.
    struct Box {
        var transform: simd_float4x4
        var halfSize: SIMD3<Float>

        var center: SIMD3<Float> { simd_make_float3(transform.columns.3) }
        func axis(_ index: Int) -> SIMD3<Float> { simd_normalize(simd_make_float3(transform[index])) }
        /// Half the box's length along `direction`.
        func radius(along direction: SIMD3<Float>) -> Float {
            (0..<3).reduce(0) { $0 + abs(simd_dot(direction, axis($1))) * halfSize[$1] }
        }
    }

    struct Wall {
        /// The wall's plane is the box's x-y plane.
        let box: Box
        /// Doorways and openings, as ranges along the wall's x axis that things can pass through.
        let gaps: [ClosedRange<Float>]
    }

    private(set) var walls: [Wall] = []
    private(set) var furniture: [Box] = []

    init(walls: [Wall] = [], furniture: [Box] = []) {
        self.walls = walls
        self.furniture = furniture
    }

    /// First solid scanned surface along a shot. Doorways stay open, as they do for movement.
    func shotDistance(from origin: SIMD3<Float>, direction: SIMD3<Float>, limit: Float = 12) -> Float? {
        func hit(_ box: Box) -> (distance: Float, local: SIMD3<Float>)? {
            let inverse = box.transform.inverse
            let start = simd_make_float3(inverse * SIMD4(origin, 1))
            let ray = simd_make_float3(inverse * SIMD4(direction, 0))
            var near: Float = 0, far = limit
            for axis in 0..<3 {
                if abs(ray[axis]) < 1e-6 {
                    if abs(start[axis]) > box.halfSize[axis] { return nil }
                } else {
                    let a = (-box.halfSize[axis] - start[axis]) / ray[axis]
                    let b = (box.halfSize[axis] - start[axis]) / ray[axis]
                    near = max(near, min(a, b))
                    far = min(far, max(a, b))
                    if near > far { return nil }
                }
            }
            return (near, start + ray * near)
        }
        var distances = furniture.compactMap { hit($0)?.distance }
        for wall in walls {
            guard let point = hit(wall.box), !wall.gaps.contains(where: { $0.contains(point.local.x) }) else { continue }
            distances.append(point.distance)
        }
        return distances.min()
    }

    init(_ structure: CapturedStructure) {
        let openings = structure.doors + structure.openings
        walls = structure.walls.map { wall in
            let inverse = wall.transform.inverse
            let gaps = openings.compactMap { opening -> ClosedRange<Float>? in
                let local = inverse * opening.transform.columns.3
                guard abs(local.z) < 0.2, abs(local.x) < wall.dimensions.x / 2 + 0.05 else { return nil }
                return (local.x - opening.dimensions.x / 2)...(local.x + opening.dimensions.x / 2)
            }
            // As thin as the walls that hide ghosts, so a body with its back on the wall fits.
            let box = Box(transform: wall.transform, halfSize: SIMD3(wall.dimensions.x / 2, wall.dimensions.y / 2, 0.01))
            return Wall(box: box, gaps: gaps)
        }
        furniture = structure.objects.map { Box(transform: $0.transform, halfSize: $0.dimensions / 2) }
    }

    /// Whether `box` is inside a wall (other than through a doorway) or a piece of furniture.
    func blocks(_ box: Box) -> Bool {
        for wall in walls where Self.overlap(box, wall.box) {
            let along = wall.box.axis(0)
            let middle = simd_dot(box.center - wall.box.center, along)
            let reach = box.radius(along: along)
            if !wall.gaps.contains(where: { $0.lowerBound <= middle - reach && middle + reach <= $0.upperBound }) {
                return true
            }
        }
        return furniture.contains { Self.overlap(box, $0) }
    }

    /// The top of the highest piece of furniture under `point` that's no more than `step` above it.
    func furnitureTop(under point: SIMD3<Float>, step: Float) -> Float? {
        furniture.compactMap { box -> Float? in
            let local = simd_make_float3(box.transform.inverse * SIMD4(point, 1))
            guard abs(local.x) <= box.halfSize.x, abs(local.z) <= box.halfSize.z else { return nil }
            let top = box.center.y + box.halfSize.y
            return top <= point.y + step ? top : nil
        }.max()
    }

    /// The closest wall within `range` of `point`, if `point` is in front of it: the spot on the wall
    /// level with `point`, and the way out of the wall toward `point`.
    func nearestWall(to point: SIMD3<Float>, within range: Float) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        var best: (point: SIMD3<Float>, normal: SIMD3<Float>, distance: Float)?
        for wall in walls {
            var normal = wall.box.axis(2)
            normal.y = 0
            guard simd_length(normal) > 0.5 else { continue }
            normal = simd_normalize(normal)
            let offset = point - wall.box.center
            let distance = simd_dot(offset, normal)
            guard abs(distance) < range, abs(distance) < best?.distance ?? .infinity,
                  abs(simd_dot(offset, wall.box.axis(0))) < wall.box.halfSize.x else { continue }
            if distance < 0 { normal = -normal }
            best = (point - normal * abs(distance), normal, abs(distance))
        }
        return best.map { ($0.point, $0.normal) }
    }

    /// Separating-axis test for two boxes.
    static func overlap(_ a: Box, _ b: Box) -> Bool {
        let axesA = (0..<3).map(a.axis), axesB = (0..<3).map(b.axis)
        var axes = axesA + axesB
        for u in axesA {
            for v in axesB {
                let cross = simd_cross(u, v)
                if simd_length(cross) > 1e-4 { axes.append(simd_normalize(cross)) }
            }
        }
        let offset = b.center - a.center
        return axes.allSatisfy { abs(simd_dot(offset, $0)) <= a.radius(along: $0) + b.radius(along: $0) }
    }
}
