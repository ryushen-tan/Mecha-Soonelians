import SceneKit

#if os(macOS)
import AppKit
private typealias AvatarColor = NSColor
#else
import UIKit
private typealias AvatarColor = UIColor
#endif

/// One closed, fully textured head on the shared white bust.
enum ProfileAvatarMesh {
    static func scene(texture: CGImage) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = AvatarColor.clear
        let white = SCNMaterial()
        white.diffuse.contents = AvatarColor(white: 0.94, alpha: 1)
        white.roughness.contents = 0.85
        white.lightingModel = .lambert

        func ellipsoid(_ name: String, scale: SCNVector3, position: SCNVector3) {
            let sphere = SCNSphere(radius: 1)
            sphere.segmentCount = 32
            sphere.materials = [white]
            let node = SCNNode(geometry: sphere)
            node.name = name
            node.scale = scale
            node.position = position
            scene.rootNode.addChildNode(node)
        }
        ellipsoid("neck", scale: SCNVector3(0.27, 0.46, 0.28), position: SCNVector3(0, -0.02, -0.04))
        ellipsoid("shoulders", scale: SCNVector3(1.18, 0.83, 0.43), position: SCNVector3(0, -0.91, -0.05))

        let face = SCNNode(geometry: headGeometry())
        face.name = "head"
        let skin = SCNMaterial()
        skin.diffuse.contents = texture
        skin.lightingModel = .lambert
        skin.diffuse.wrapS = .repeat
        skin.diffuse.wrapT = .clamp
        skin.isDoubleSided = false
        face.geometry?.materials = [skin]
        scene.rootNode.addChildNode(face)

        let camera = SCNNode()
        camera.name = "avatar-camera"
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.4
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 100
        camera.position = SCNVector3(0, 0.32, 7)
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        ambient.light?.color = AvatarColor.white
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 550
        key.position = SCNVector3(-3, 4, 6)
        scene.rootNode.addChildNode(key)
        return scene
    }

    private static func headGeometry() -> SCNGeometry {
        let columns = 64, rows = 48
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uv: [CGPoint] = []
        var indices: [UInt32] = []
        for row in 0...rows {
            let v = Double(row) / Double(rows)
            let pitch = (0.5 - v) * .pi
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let yaw = (u - 0.5) * 2 * .pi
                let x = sin(yaw) * cos(pitch), y = sin(pitch), z = cos(yaw) * cos(pitch)
                vertices.append(SCNVector3(0.66 * x, 0.8 + 0.83 * y, 0.57 * z))
                let nx = x / 0.66, ny = y / 0.83, nz = z / 0.57
                let length = sqrt(nx * nx + ny * ny + nz * nz)
                normals.append(SCNVector3(nx / length, ny / length, nz / length))
                uv.append(CGPoint(x: u, y: v))
                if row < rows && column < columns {
                    let a = UInt32(row * (columns + 1) + column), b = a + 1
                    let c = a + UInt32(columns + 1), d = c + 1
                    indices.append(contentsOf: [a, c, b, b, c, d])
                }
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                    SCNGeometrySource(textureCoordinates: uv)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }
}
