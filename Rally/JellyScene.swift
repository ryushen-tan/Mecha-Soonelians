import CoreMotion
import SpriteKit
import SwiftUI

/// Publishes only the small landing overlay; physics never invalidates the lobby form.
final class JellySceneState: ObservableObject {
    @Published var count = 0
    @Published var filled = false
    @Published var tiltEnabled = false
    let playPosition = JellyPlayPosition()
    let scene = JellyScene()

    init() { scene.state = self }
}

final class JellyPlayPosition: ObservableObject {
    @Published var frame = CGRect.zero
}

final class JellyScene: SKScene {
    weak var state: JellySceneState?
    private let figures = SKEffectNode()
    private let cardFloor = SKNode()
    private let motion = CMMotionManager()
    private var textures: [SKTexture] = []
    private var play: SKSpriteNode?
    private var title: SKSpriteNode?
    private var nextSpawn = 0.0
    private var finishTime = 0.0
    private var lastPublished = 0.0
    private var count = 0
    private var target = 0
    private var reducedMotion = false
    private var suspended = false
    private var dragging: SKNode?
    private var previousTouch: CGPoint?
    private var touchTime: TimeInterval = 0
    private var throwVelocity = CGVector.zero

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = UIColor(JellyStyle.background)
        figures.shouldEnableEffects = false
        addChild(figures)
        addChild(cardFloor)
        for pose in 1...8 {
            guard let url = Bundle.main.url(forResource: "pose-\(pose)", withExtension: "png", subdirectory: "JellyAssets/sprites"),
                  let image = UIImage(contentsOfFile: url.path) else { continue }
            textures.append(Self.figureTexture(image, white: false))
            textures.append(Self.figureTexture(image, white: true))
        }
    }

    override convenience init() { self.init(size: CGSize(width: 390, height: 844)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMove(to view: SKView) { refill() }
    override func didChangeSize(_ oldSize: CGSize) {
        if view != nil, size.width > 0, size.height > 0 { refill() }
    }

    func configure(reducedMotion: Bool, suspended: Bool) {
        let changed = self.reducedMotion != reducedMotion
        self.reducedMotion = reducedMotion
        self.suspended = suspended
        isPaused = suspended
        if suspended || reducedMotion { stopTilt() }
        if changed { refill() }
    }

    func toggleTilt() {
        guard !reducedMotion, !suspended else { return }
        if motion.isDeviceMotionActive { stopTilt(); return }
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates()
        state?.tiltEnabled = true
        unblur()
    }

    var supportsTilt: Bool { motion.isDeviceMotionAvailable }

    private func stopTilt() {
        motion.stopDeviceMotionUpdates()
        state?.tiltEnabled = false
        physicsWorld.gravity = CGVector(dx: 0, dy: -9.4)
    }

    func refill() {
        stopTilt()
        figures.removeAllChildren()
        play?.removeFromParent(); title?.removeFromParent()
        play = nil; title = nil
        count = 0; nextSpawn = 0; finishTime = 0
        dragging = nil; previousTouch = nil
        physicsBody = SKPhysicsBody(edgeLoopFrom: CGRect(x: 0, y: 0, width: size.width, height: size.height + pieceSize * 2))
        physicsBody?.friction = 0.4
        // Figurines fill the screen; interactive cards stop above the bottom HUD.
        cardFloor.physicsBody = SKPhysicsBody(edgeFrom: CGPoint(x: 0, y: 110), to: CGPoint(x: size.width, y: 110))
        cardFloor.physicsBody?.categoryBitMask = 2
        cardFloor.physicsBody?.collisionBitMask = 4
        // Leave headroom for the wide title body and the safe-area HUD on phones.
        target = min(150, max(24, Int(size.width * size.height * 0.48 / (pieceSize * pieceSize * 0.72))))
        state?.count = 0; state?.filled = false; state?.playPosition.frame = .zero
        figures.shouldEnableEffects = false
        if reducedMotion {
            for index in 0..<target {
                let node = spawnPiece(index)
                let columns = max(3, Int(size.width / (pieceSize * 0.8)))
                node.position = CGPoint(x: CGFloat(index % columns) * pieceSize * 0.8 + pieceSize * 0.4,
                                        y: CGFloat(index / columns) * pieceSize * 0.65 + pieceSize * 0.4)
                node.physicsBody?.isDynamic = false
            }
            count = target
            addCard(isTitle: true, at: CGPoint(x: size.width / 2, y: size.height * 0.72))
            addCard(isTitle: false, at: CGPoint(x: size.width / 2, y: size.height * 0.3))
            state?.count = count; state?.filled = true
            setBlur()
            publishPlayFrame()
        }
    }

    private var pieceSize: CGFloat { min(size.height / 9, size.width / 4.4) }

    override func update(_ currentTime: TimeInterval) {
        guard !reducedMotion, !suspended else { return }
        if let gravity = motion.deviceMotion?.gravity {
            physicsWorld.gravity = CGVector(dx: gravity.x * 9.4, dy: min(-0.8, gravity.y * 9.4))
        }
        if count < target, currentTime >= nextSpawn {
            _ = spawnPiece(count)
            count += 1
            state?.count = count
            nextSpawn = currentTime + Double.random(in: 0.086...0.141)
            if count == 5 { addCard(isTitle: false) }
            if count == target { finishTime = currentTime; state?.filled = true }
        }
        if count == target, title == nil, currentTime > finishTime + 0.3 { addCard(isTitle: true) }
        if finishTime > 0, currentTime > finishTime + 4, dragging == nil, !motion.isDeviceMotionActive { setBlur() }
        if currentTime - lastPublished > 1.0 / 30 {
            publishPlayFrame()
            lastPublished = currentTime
        }
    }

    @discardableResult private func spawnPiece(_ index: Int) -> SKSpriteNode {
        let node: SKSpriteNode
        let letters = [6: "S", 11: "O", 16: "O", 21: "N"]
        if let letter = letters[index] {
            node = SKSpriteNode(texture: Self.blueTexture(letter))
        } else if index == 3 {
            node = SKSpriteNode(texture: Self.blueTexture(nil))
        } else if let texture = textures.randomElement() {
            node = SKSpriteNode(texture: texture)
        } else {
            node = SKSpriteNode(color: UIColor(JellyStyle.ink), size: CGSize(width: 40, height: 60))
        }
        let ratio = node.size.width / max(node.size.height, 1)
        let extent = pieceSize * CGFloat.random(in: 0.85...1.1)
        node.size = ratio > 1 ? CGSize(width: extent, height: extent / ratio) : CGSize(width: extent * ratio, height: extent)
        node.position = CGPoint(x: CGFloat.random(in: extent / 2...max(extent / 2, size.width - extent / 2)), y: size.height + extent)
        node.zRotation = CGFloat.random(in: -0.8...0.8)
        node.name = "figure"
        let body = SKPhysicsBody(circleOfRadius: extent * 0.44)
        body.restitution = 0.6; body.friction = 0.4
        body.linearDamping = 0.12; body.angularDamping = 0.6
        body.mass = extent * extent / 12_000
        body.categoryBitMask = 1; body.collisionBitMask = 1 | 4
        body.velocity = CGVector(dx: CGFloat.random(in: -45...45), dy: -80)
        body.angularVelocity = CGFloat.random(in: -1.5...1.5)
        node.physicsBody = body
        figures.addChild(node)
        return node
    }

    private func addCard(isTitle: Bool, at position: CGPoint? = nil) {
        let width = isTitle ? min(size.width - 52, 340) : min(size.width * 0.47, 200)
        let cardSize = CGSize(width: width, height: isTitle ? width * 0.32 : width * 0.36)
        let node = SKSpriteNode(texture: Self.cardTexture(size: cardSize, title: isTitle), size: cardSize)
        node.position = position ?? CGPoint(x: size.width / 2, y: size.height + cardSize.height)
        node.zPosition = 2
        let body = SKPhysicsBody(rectangleOf: cardSize)
        body.allowsRotation = false; body.restitution = 0.24; body.friction = 0.6
        body.mass = 1.2; body.linearDamping = 0.5; body.isDynamic = !reducedMotion
        body.categoryBitMask = 4; body.collisionBitMask = 1 | 2 | 4
        node.physicsBody = body
        addChild(node)
        if isTitle { title = node } else { play = node }
    }

    private func publishPlayFrame() {
        guard let play else { return }
        let frame = CGRect(x: play.position.x - play.size.width / 2,
                                 y: size.height - play.position.y - play.size.height / 2,
                                 width: play.size.width, height: play.size.height)
        if state?.playPosition.frame != frame { state?.playPosition.frame = frame }
    }

    private func setBlur() {
        guard !figures.shouldEnableEffects else { return }
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(4.0, forKey: kCIInputRadiusKey)
        figures.filter = filter
        figures.shouldEnableEffects = true
    }

    private func unblur() { figures.shouldEnableEffects = false; finishTime = 0 }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !reducedMotion, let touch = touches.first else { return }
        let point = touch.location(in: self)
        unblur()
        dragging = figures.nodes(at: point).first { $0.name == "figure" }
        dragging?.physicsBody?.isDynamic = false
        previousTouch = point; touchTime = touch.timestamp; throwVelocity = .zero
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !reducedMotion, let touch = touches.first, let previousTouch else { return }
        let point = touch.location(in: self)
        let delta = max(touch.timestamp - touchTime, 1.0 / 120)
        throwVelocity = CGVector(dx: min(1000, max(-1000, (point.x - previousTouch.x) / delta)),
                                 dy: min(1000, max(-1000, (point.y - previousTouch.y) / delta)))
        if let dragging {
            dragging.position = CGPoint(x: min(size.width - pieceSize / 2, max(pieceSize / 2, point.x)),
                                        y: min(size.height - pieceSize / 2, max(pieceSize / 2, point.y)))
        } else {
            physicsWorld.gravity = CGVector(dx: min(9.4, max(-9.4, (point.x - previousTouch.x) * 0.5)), dy: -9.4)
        }
        self.previousTouch = point; touchTime = touch.timestamp
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finishDrag() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finishDrag() }
    private func finishDrag() {
        dragging?.physicsBody?.isDynamic = true
        dragging?.physicsBody?.velocity = throwVelocity
        dragging = nil; previousTouch = nil
        if !motion.isDeviceMotionActive { physicsWorld.gravity = CGVector(dx: 0, dy: -9.4) }
        // Schedule the same settling blur after an interaction as after the initial pour.
        if count == target { finishTime = touchTime }
    }

    deinit { motion.stopDeviceMotionUpdates() }

    private static func figureTexture(_ image: UIImage, white: Bool) -> SKTexture {
        let padding = ceil(max(image.size.width, image.size.height) * 0.028)
        let size = CGSize(width: image.size.width + padding * 2, height: image.size.height + padding * 2)
        let ink = UIColor(JellyStyle.ink), paper = UIColor(JellyStyle.paper)
        let border = image.withTintColor(white ? ink : paper, renderingMode: .alwaysOriginal)
        let fill = image.withTintColor(white ? paper : ink, renderingMode: .alwaysOriginal)
        let result = UIGraphicsImageRenderer(size: size).image { _ in
            for step in 0..<16 {
                let angle = Double(step) / 16 * .pi * 2
                border.draw(at: CGPoint(x: padding + cos(angle) * padding, y: padding + sin(angle) * padding))
            }
            fill.draw(at: CGPoint(x: padding, y: padding))
        }
        return SKTexture(image: result)
    }

    private static func cardTexture(size: CGSize, title: Bool) -> SKTexture {
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
            (title ? UIColor(JellyStyle.paper) : UIColor(JellyStyle.blue)).setFill(); path.fill()
            UIColor(JellyStyle.ink).setStroke(); path.lineWidth = 3; path.stroke()
            let style = NSMutableParagraphStyle(); style.alignment = .center
            func text(_ value: String, fontSize: CGFloat, y: CGFloat, tracking: CGFloat = 0) {
                let font = UIFont(name: "Outfit-Thin_ExtraBold", size: fontSize) ?? .boldSystemFont(ofSize: fontSize)
                (value as NSString).draw(in: CGRect(x: 5, y: y, width: size.width - 10, height: size.height), withAttributes: [
                    .font: font, .foregroundColor: title ? UIColor(JellyStyle.ink) : UIColor.white,
                    .paragraphStyle: style, .kern: tracking
                ])
            }
            if title {
                text("MECCHA", fontSize: size.width * 0.045, y: size.height * 0.15, tracking: 4)
                text("SOONELIANS", fontSize: size.width * 0.105, y: size.height * 0.38)
            } else {
                text("▸ PLAY", fontSize: size.width * 0.18, y: size.height * 0.19, tracking: 2)
            }
        }
        return SKTexture(image: image)
    }

    private static func blueTexture(_ letter: String?) -> SKTexture {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
            let path = UIBezierPath()
            if letter == "O" { path.append(UIBezierPath(ovalIn: CGRect(x: 28, y: 22, width: 64, height: 76))) }
            else if letter == "N" {
                path.move(to: CGPoint(x: 26, y: 98)); path.addLine(to: CGPoint(x: 26, y: 22))
                path.addLine(to: CGPoint(x: 94, y: 98)); path.addLine(to: CGPoint(x: 94, y: 22))
            } else if letter == "S" {
                path.move(to: CGPoint(x: 87, y: 27))
                path.addCurve(to: CGPoint(x: 53, y: 60), controlPoint1: CGPoint(x: 24, y: 0), controlPoint2: CGPoint(x: 10, y: 53))
                path.addCurve(to: CGPoint(x: 30, y: 94), controlPoint1: CGPoint(x: 124, y: 72), controlPoint2: CGPoint(x: 90, y: 122))
            } else {
                path.move(to: CGPoint(x: 64, y: 17)); path.addLine(to: CGPoint(x: 103, y: 57))
                path.move(to: CGPoint(x: 17, y: 94)); path.addLine(to: CGPoint(x: 92, y: 94)); path.addLine(to: CGPoint(x: 92, y: 72))
                path.move(to: CGPoint(x: 42, y: 55)); path.addLine(to: CGPoint(x: 46, y: 59))
            }
            path.lineWidth = 22; path.lineCapStyle = .round; path.lineJoinStyle = .round
            context.cgContext.setShadow(offset: CGSize(width: 1, height: 4), blur: 3, color: UIColor(JellyStyle.ink).withAlphaComponent(0.3).cgColor)
            UIColor(red: 0.19, green: 0.24, blue: 0.7, alpha: 1).setStroke(); path.stroke()
            context.cgContext.setShadow(offset: .zero, blur: 0)
            context.cgContext.translateBy(x: 0, y: -2)
            path.lineWidth = 18; UIColor(JellyStyle.blue).setStroke(); path.stroke()
        }
        return SKTexture(image: image)
    }
}
