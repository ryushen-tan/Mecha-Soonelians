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

/// Front-camera turnaround: the player props the phone up, stands back, and turns a little to
/// their right at each beep while it takes eight shots.
final class ChameleonCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Stage: Equatable {
        case framing
        case countdown(Int)
        case shooting(Int)
        case processing
        case done
        case failed(String)
    }

    static let shots = 8

    @Published private(set) var stage = Stage.framing
    @Published private(set) var fullBodyInView = false
    @Published private(set) var views: [ChameleonView] = []

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "chameleon.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private let speech = AVSpeechSynthesizer()
    private var framingTask: Task<Void, Never>?

    func start() {
        stage = .framing
        views = []
        fullBodyInView = false
        queue.async { [self] in
            guard session.inputs.isEmpty else { session.startRunning(); return }
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.stage = .failed("Couldn't open the front camera.") }
                return
            }
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
                self.fullBodyInView = await self.checkFraming()
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
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
    }

    private func latestImage() -> CGImage? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(image, from: image.extent)
    }

    /// The whole body has to be in the frame with a little room at the top and bottom.
    private func checkFraming() async -> Bool {
        guard let image = latestImage() else { return false }
        return await Task.detached {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .fast
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
                  let mask = request.results?.first?.pixelBuffer,
                  let box = ChameleonCapture.maskBounds(mask) else { return false }
            let height = CGFloat(CVPixelBufferGetHeight(mask))
            return box.minY > height * 0.03 && box.maxY < height * 0.97 && box.height > height * 0.45
        }.value
    }

    @MainActor
    func run() async {
        guard stage == .framing else { return }
        framingTask?.cancel()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
        say("Got you. Arms out a little. Starting in five.")
        for second in stride(from: 5, through: 1, by: -1) {
            stage = .countdown(second)
            try? await Task.sleep(for: .seconds(1))
        }
        var shots: [CGImage] = []
        for shot in 0..<Self.shots {
            stage = .shooting(shot)
            if shot > 0 {
                say("Turn")
                try? await Task.sleep(for: .seconds(2.6))
            }
            AudioServicesPlaySystemSound(1108)
            if let image = latestImage() { shots.append(image) }
            try? await Task.sleep(for: .milliseconds(300))
        }
        say("Done!")
        stage = .processing
        stop()
        views = await Task.detached { Self.process(shots) }.value
        stage = views.count >= 4 ? .done : .failed("Couldn't see you in enough shots. Make sure your whole body is in view.")
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.55
        speech.speak(utterance)
    }

    /// Cuts the person out of each shot and finds their hips. Shot i is i × 45° into the turn.
    private static func process(_ shots: [CGImage]) -> [ChameleonView] {
        shots.enumerated().compactMap { index, photo in
            guard let (person, bounds) = try? GhostCapture.cutOut(photo),
                  bounds.height > CGFloat(photo.height) * 0.3,
                  let crop = person.cropping(to: bounds),
                  let png = UIImage(cgImage: crop).pngData() else { return nil }
            var centerX = 0.5
            let pose = VNDetectHumanBodyPoseRequest()
            if (try? VNImageRequestHandler(cgImage: photo).perform([pose])) != nil,
               let root = try? pose.results?.first?.recognizedPoint(.root), root.confidence > 0.3 {
                let x = root.location.x * CGFloat(photo.width)
                centerX = min(max(Double((x - bounds.minX) / bounds.width), 0.2), 0.8)
            }
            return ChameleonView(png: png, yaw: Double(index) * 360 / Double(shots.count), centerX: centerX)
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
