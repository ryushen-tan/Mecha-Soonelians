import AVFoundation
import SwiftUI
import Vision

/// The player's chameleon: four photos of them mapped onto the chameleon body (BlueMan's rig, CC BY 4.0), saved as GLB.
enum ChameleonStore {
    /// Every chameleon stands this tall in the house, whoever made it.
    static let height: Float = 1.0

    private static var directory: URL { HouseStore.documents.appendingPathComponent("Chameleon", isDirectory: true) }
    static var modelURL: URL { directory.appendingPathComponent("chameleon.glb") }
    static var hasChameleon: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    static func save(_ model: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try model.write(to: modelURL, options: .atomic)
    }

    static func load() -> Data? { try? Data(contentsOf: modelURL) }
}

/// One photo of the player: cut out and cropped head-to-feet, with their body joints.
struct ChameleonView {
    let png: Data
    /// How far they'd turned to their right: 0 front, 90, 180 back, 270.
    let yaw: Double
    /// Vision body joints in crop pixels from the top-left: name → [x, y, confidence].
    let keypoints: [String: [Double]]

    var viewerArguments: [String: Any] { ["image": png.base64EncodedString(), "yaw": yaw, "keypoints": keypoints] }
}

/// Front-camera photos from four sides, Minecraft-skin style: the player props the phone up and
/// walks back; once they're fully in view with their arms out, it locks exposure and colors and
/// talks them through a front, side, back and other-side photo.
final class ChameleonCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Stage: Equatable {
        case framing
        case countdown(Int)
        /// Which of the four photos is next (0 front … 3 other side).
        case photo(Int)
        case processing
        case done
        case failed(String)
    }

    /// The four photos: how far round, what to say, and whether the face must (or must not) show.
    private static let sides: [(yaw: Double, say: String, face: Bool?)] = [
        (0, "Face me and hold still.", true),
        (90, "Turn to your right, and hold still.", nil),
        (180, "Turn right again, back to me. Hold still.", false),
        (270, "One more turn to the right. Hold still.", nil),
    ]
    static var photoCount: Int { sides.count }

    enum Framing { case notInView, armsDown, ready }

    @Published private(set) var stage = Stage.framing
    @Published private(set) var framing = Framing.notInView
    var fullBodyInView: Bool { framing == .ready }
    @Published private(set) var views: [ChameleonView] = []

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "chameleon.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var camera: AVCaptureDevice?
    private let speech = AVSpeechSynthesizer()
    private var framingTask: Task<Void, Never>?

    func start() {
        stage = .framing
        views = []
        framing = .notInView
        queue.async { [self] in
            guard session.inputs.isEmpty else { session.startRunning(); return }
            session.beginConfiguration()
            session.sessionPreset = .hd1920x1080
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.stage = .failed("Couldn't open the front camera.") }
                return
            }
            camera = device
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            // Upright portrait frames, not mirrored: the mapping relies on the person's left
            // appearing on the image's right, as the camera really sees them.
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()
            session.startRunning()
        }
        framingTask = Task { @MainActor [weak self] in
            var inViewStreak = 0
            while !Task.isCancelled, let self, self.stage == .framing {
                self.framing = await self.checkFraming()
                // The player is across the room, so start by itself once they've been fully in view
                // for about two seconds.
                inViewStreak = self.fullBodyInView ? inViewStreak + 1 : 0
                if inViewStreak >= 3, self.stage == .framing {
                    Task { await self.run() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    func stop() {
        framingTask?.cancel()
        setCameraLocked(false)
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
    }

    private func latestImage(scale: CGFloat = 1) -> CGImage? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        if scale != 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return CIContext().createCGImage(image, from: image.extent)
    }

    /// Exposure and white balance stay put across the four photos, so they all have the same colors.
    private func setCameraLocked(_ locked: Bool) {
        guard let camera, (try? camera.lockForConfiguration()) != nil else { return }
        let exposure: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
        let whiteBalance: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
        if camera.isExposureModeSupported(exposure) { camera.exposureMode = exposure }
        if camera.isWhiteBalanceModeSupported(whiteBalance) { camera.whiteBalanceMode = whiteBalance }
        camera.unlockForConfiguration()
    }

    /// Ready when the whole body is in the frame (with a little room at the top and bottom) and the
    /// arms are held out from the sides, matching the chameleon body's pose.
    private func checkFraming() async -> Framing {
        guard let image = latestImage(scale: 0.5) else { return .notInView }
        return await Task.detached {
            let segmentation = VNGeneratePersonSegmentationRequest()
            segmentation.qualityLevel = .fast
            let pose = VNDetectHumanBodyPoseRequest()
            guard (try? VNImageRequestHandler(cgImage: image).perform([segmentation, pose])) != nil,
                  let mask = segmentation.results?.first?.pixelBuffer,
                  let box = ChameleonCapture.maskBounds(mask) else { return .notInView }
            let height = CGFloat(CVPixelBufferGetHeight(mask))
            guard box.minY > height * 0.03, box.maxY < height * 0.97, box.height > height * 0.45 else { return .notInView }
            // Wrists well out from the hips, sideways (normalized image coordinates; the frame is portrait).
            guard let body = pose.results?.first,
                  let root = try? body.recognizedPoint(.root), root.confidence > 0.3,
                  let left = try? body.recognizedPoint(.leftWrist), left.confidence > 0.3,
                  let right = try? body.recognizedPoint(.rightWrist), right.confidence > 0.3 else { return .armsDown }
            let bodyWidth = box.height / CGFloat(CVPixelBufferGetWidth(mask))
            let out = min(abs(left.location.x - root.location.x), abs(right.location.x - root.location.x))
            return out > bodyWidth * 0.18 ? .ready : .armsDown
        }.value
    }

    @MainActor
    func run() async {
        guard stage == .framing else { return }
        framingTask?.cancel()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
        setCameraLocked(true)
        say("Got you. Keep your arms out a little for four photos.")
        for second in stride(from: 3, through: 1, by: -1) {
            stage = .countdown(second)
            try? await Task.sleep(for: .seconds(1))
        }
        var photos: [(yaw: Double, image: CGImage)] = []
        for (index, side) in Self.sides.enumerated() {
            stage = .photo(index)
            say(side.say)
            try? await Task.sleep(for: .seconds(index == 0 ? 2 : 3))
            // Wait (up to 3 more seconds) until the face shows or hides as it should from this side.
            var image = latestImage()
            if let wantFace = side.face {
                for _ in 0..<10 {
                    guard let candidate = latestImage() else { break }
                    image = candidate
                    let hasFace = await Task.detached { Self.hasFrontFace(candidate) }.value
                    if hasFace == wantFace { break }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            AudioServicesPlaySystemSound(1108)
            if let image { photos.append((side.yaw, image)) }
        }
        say("Done!")
        stage = .processing
        stop()
        views = await Task.detached { Self.process(photos) }.value
        stage = views.count >= 3 ? .done : .failed("Couldn't see you in enough photos. Keep your whole body in view and try again.")
    }

    private func say(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        speech.speak(utterance)
    }

    /// Whether a face is turned mostly toward the camera.
    private static func hasFrontFace(_ image: CGImage) -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return false }
        return abs((face.yaw?.doubleValue ?? 0) * 180 / .pi) < 40
    }

    /// Cuts the person out of each photo and finds their joints, in crop pixels.
    private static func process(_ photos: [(yaw: Double, image: CGImage)]) -> [ChameleonView] {
        let joints: [(String, VNHumanBodyPoseObservation.JointName)] = [
            ("nose", .nose), ("neck", .neck), ("root", .root),
            ("leftShoulder", .leftShoulder), ("rightShoulder", .rightShoulder),
            ("leftElbow", .leftElbow), ("rightElbow", .rightElbow),
            ("leftWrist", .leftWrist), ("rightWrist", .rightWrist),
            ("leftHip", .leftHip), ("rightHip", .rightHip),
            ("leftKnee", .leftKnee), ("rightKnee", .rightKnee),
            ("leftAnkle", .leftAnkle), ("rightAnkle", .rightAnkle),
        ]
        return photos.compactMap { yaw, photo in
            guard let (person, bounds) = try? GhostCapture.cutOut(photo),
                  bounds.height > CGFloat(photo.height) * 0.3,
                  let crop = person.cropping(to: bounds),
                  let png = UIImage(cgImage: crop).pngData() else { return nil }
            var keypoints: [String: [Double]] = [:]
            let pose = VNDetectHumanBodyPoseRequest()
            if (try? VNImageRequestHandler(cgImage: photo).perform([pose])) != nil, let body = pose.results?.first {
                for (name, joint) in joints {
                    guard let point = try? body.recognizedPoint(joint), point.confidence > 0.1 else { continue }
                    // Vision: normalized, origin bottom-left. The crop: pixels, origin top-left.
                    let x = point.location.x * CGFloat(photo.width) - bounds.minX
                    let y = (1 - point.location.y) * CGFloat(photo.height) - bounds.minY
                    keypoints[name] = [Double(x), Double(y), Double(point.confidence)]
                }
            }
            return ChameleonView(png: png, yaw: yaw, keypoints: keypoints)
        }
    }

    /// Bounding box of person pixels in a segmentation mask, in mask pixels from the top-left.
    fileprivate static func maskBounds(_ mask: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = pixels + y * rowBytes
            for x in 0..<width where row[x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Mirrored live preview, so standing in front of it feels like a mirror.
struct TurnaroundPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        }
    }
}
