import AVFoundation
import SwiftUI
import Vision

/// The player's chameleon: their 360° turnaround mapped onto the chameleon body (BlueMan's rig, CC BY 4.0), saved as GLB.
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

/// One shot of the turnaround: the person cut out and cropped head-to-feet.
struct ChameleonView {
    let png: Data
    /// How far they've turned to their right, in degrees.
    let yaw: Double
    /// Where their hips are across the crop, 0–1.
    let centerX: Double

    var viewerArguments: [String: Any] { ["image": png.base64EncodedString(), "yaw": yaw, "centerX": centerX] }
}

/// Front-camera turnaround: the player props the phone up and walks back; once they're fully in
/// view it locks the camera's exposure and colors, and records them spinning slowly once to their
/// right. It stops when their face comes back around, then keeps the clearest frame every 15°.
final class ChameleonCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Stage: Equatable {
        case framing
        case countdown(Int)
        case spinning(Double)
        case processing
        case done
        case failed(String)
    }

    /// Frames kept from the spin, one per this many degrees.
    static let step = 15.0
    private static let frameInterval = 0.2
    private static let longestSpin = 16.0

    @Published private(set) var stage = Stage.framing
    enum Framing { case notInView, armsDown, ready }

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

    /// One recorded frame and what the face detector saw in it.
    private struct Frame {
        let time: Double
        let jpeg: Data
        /// Face turn in degrees (unsigned), when a face is visible.
        let faceYaw: Double?
        /// Face center across the frame, 0–1, when visible.
        let faceX: Double?
    }

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
            // Upright portrait frames, not mirrored: the projection relies on the person's left
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

    /// Exposure and white balance stay put during the spin, so every frame has the same colors.
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
        say("Got you. Hold your arms out a little. When you hear the beep, spin slowly to your right, all the way around.")
        for second in stride(from: 5, through: 1, by: -1) {
            stage = .countdown(second)
            try? await Task.sleep(for: .seconds(1))
        }
        AudioServicesPlaySystemSound(1113)

        // Record until the face has gone around the back and come back to the front.
        var frames: [Frame] = []
        let started = Date()
        var faceGoneSince: Double?
        var wentAround = false
        while true {
            let time = Date().timeIntervalSince(started)
            stage = .spinning(time)
            if let image = latestImage(scale: 2.0 / 3.0) {
                let face = await Task.detached { Self.face(in: image) }.value
                if let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) {
                    frames.append(Frame(time: time, jpeg: jpeg, faceYaw: face?.yaw, faceX: face?.x))
                }
                if face == nil {
                    faceGoneSince = faceGoneSince ?? time
                    if time - faceGoneSince! > 0.8 { wentAround = true }
                } else {
                    faceGoneSince = nil
                    if wentAround, let yaw = face?.yaw, yaw < 30, time > 3 { break }
                }
            }
            if time > Self.longestSpin { break }
            try? await Task.sleep(for: .seconds(Self.frameInterval))
        }
        AudioServicesPlaySystemSound(1114)
        say("Got it!")
        stage = .processing
        stop()
        views = await Task.detached { Self.process(frames) }.value
        stage = views.count >= 8 ? .done : .failed("Couldn't follow your spin. Spin slowly, keep your whole body in view, and try again.")
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        speech.speak(utterance)
    }

    /// The most prominent face's turn (unsigned degrees) and center across the frame.
    private static func face(in image: CGImage) -> (yaw: Double, x: Double)? {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let yaw = abs((face.yaw?.doubleValue ?? 0) * 180 / .pi)
        return (yaw, Double(face.boundingBox.midX))
    }

    /// The spin's shape from the face: the longest stretch without a face is the back turned to the
    /// camera; the spin ends when the face comes back to the front. Nil if there's no such stretch.
    private static func spinBounds(_ frames: [Frame]) -> (backStart: Int, backEnd: Int, end: Int)? {
        var best: (start: Int, end: Int)?
        var runStart: Int?
        for (index, frame) in frames.enumerated() {
            if frame.faceYaw == nil {
                runStart = runStart ?? index
            } else if let start = runStart {
                if best == nil || frames[index].time - frames[start].time > frames[best!.end].time - frames[best!.start].time {
                    best = (start, index)
                }
                runStart = nil
            }
        }
        guard let best, frames[best.end].time - frames[best.start].time > 0.6 else { return nil }
        let end = frames[best.end...].firstIndex(where: { ($0.faceYaw ?? 90) < 30 })
            ?? frames[best.end...].lastIndex(where: { $0.faceYaw != nil }) ?? best.end
        return (best.start, best.end, end)
    }

    /// How far round each frame is. The face pins down the front half: at the start its turn grows
    /// from 0° to about 90°, and at the end it shrinks back from about 270° to 360°. Between those,
    /// while the back is to the camera, the spin is assumed steady.
    private static func yaws(for frames: [Frame], backStart: Int, backEnd: Int) -> [Double] {
        var anchors: [(time: Double, yaw: Double)] = [(frames[0].time, 0)]
        var lastYaw = 0.0
        for frame in frames[..<backStart] {
            guard let yaw = frame.faceYaw, yaw > lastYaw else { continue }
            lastYaw = min(yaw, 85)
            anchors.append((frame.time, lastYaw))
        }
        var tail: [(time: Double, yaw: Double)] = []
        var nextYaw = 360.0
        for frame in frames[backEnd...].reversed() {
            guard let yaw = frame.faceYaw, 360 - yaw < nextYaw else { continue }
            nextYaw = max(360 - yaw, 275)
            tail.insert((frame.time, nextYaw), at: 0)
        }
        anchors += tail
        if anchors.last!.time < frames.last!.time { anchors.append((frames.last!.time, 360)) }
        return frames.map { frame in
            guard let after = anchors.firstIndex(where: { $0.time >= frame.time }) else { return 360 }
            if after == 0 { return anchors[0].yaw }
            let a = anchors[after - 1], b = anchors[after]
            let t = b.time > a.time ? (frame.time - a.time) / (b.time - a.time) : 0
            return a.yaw + (b.yaw - a.yaw) * t
        }
    }

    /// Keeps the frame nearest each 15° step, cuts the person out and finds their hips.
    private static func process(_ allFrames: [Frame]) -> [ChameleonView] {
        guard let bounds = spinBounds(allFrames) else {
            saveLog(allFrames, yaws: nil)
            return []
        }
        let frames = Array(allFrames[...bounds.end])
        var yaws = yaws(for: frames, backStart: bounds.backStart, backEnd: bounds.backEnd)
        // They were told to turn right; if the face drifted the other way, they turned left.
        let early = frames.prefix(while: { $0.time < 1.2 }).compactMap(\.faceX)
        if let first = early.first, let lastX = early.last, lastX - first > 0.03 {
            // Turning right swings the face toward the camera's left (smaller x). It went right instead.
            yaws = yaws.map { $0 == 0 ? 0 : 360 - $0 }
        }
        saveLog(allFrames, yaws: yaws)
        var views: [ChameleonView] = []
        for target in stride(from: 0.0, to: 360, by: step) {
            guard let best = yaws.indices.min(by: { angleGap(yaws[$0], target) < angleGap(yaws[$1], target) }),
                  angleGap(yaws[best], target) < step,
                  let photo = UIImage(data: frames[best].jpeg)?.cgImage,
                  let (person, bounds) = try? GhostCapture.cutOut(photo),
                  bounds.height > CGFloat(photo.height) * 0.3,
                  let crop = person.cropping(to: bounds),
                  let png = UIImage(cgImage: crop).pngData() else { continue }
            var centerX = 0.5
            let pose = VNDetectHumanBodyPoseRequest()
            if (try? VNImageRequestHandler(cgImage: photo).perform([pose])) != nil,
               let root = try? pose.results?.first?.recognizedPoint(.root), root.confidence > 0.3 {
                let x = root.location.x * CGFloat(photo.width)
                centerX = min(max(Double((x - bounds.minX) / bounds.width), 0.2), 0.8)
            }
            views.append(ChameleonView(png: png, yaw: yaws[best].truncatingRemainder(dividingBy: 360), centerX: centerX))
        }
        return views
    }

    /// What the face detector saw and the angles worked out, for debugging a bad spin later
    /// (Documents/Chameleon/last-spin.json).
    private static func saveLog(_ frames: [Frame], yaws: [Double]?) {
        let entries = frames.enumerated().map { index, frame -> [String: Any] in
            var entry: [String: Any] = ["time": frame.time]
            if let yaw = frame.faceYaw { entry["faceYaw"] = yaw }
            if let x = frame.faceX { entry["faceX"] = x }
            if let yaws, index < yaws.count { entry["yaw"] = yaws[index] }
            return entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["frames": entries], options: .prettyPrinted) else { return }
        let directory = ChameleonStore.modelURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("last-spin.json"))
    }

    private static func angleGap(_ a: Double, _ b: Double) -> Double {
        let gap = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(gap, 360 - gap)
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
