import AVFoundation
import SwiftUI
import Vision

final class PersonCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var status = "Starting camera…"
    @Published var peopleCount = 0
    @Published var isCapturing = false
    @Published var depthEnabled = false
    let session = AVCaptureSession()
    var onCapture: ((Data) -> Void)?
    private let queue = DispatchQueue(label: "mecha.person-camera")
    private let visionQueue = DispatchQueue(label: "mecha.live-human-detection")
    private let photoOutput = AVCapturePhotoOutput()
    private var lastDetection = CMTime.zero
    private var wantsRunning = false

    func start() {
        #if targetEnvironment(simulator)
        status = "Live capture needs an iPhone. Close this screen and use the human sample or import a photo."
        return
        #else
        queue.async {
            self.wantsRunning = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.queue.async {
                        if granted && self.wantsRunning { self.configure() }
                        else { self.publish("Allow camera access in Settings to scan a person.") }
                    }
                }
            default: self.publish("Allow camera access in Settings to scan a person.")
            }
        }
        #endif
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() {
        guard wantsRunning else { return }
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            publish("No camera available. Import a photo instead.")
            return
        }
        do {
            session.beginConfiguration()
            session.sessionPreset = .photo
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(photoOutput) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
            if device.deviceType == .builtInLiDARDepthCamera,
               let format = device.formats.last(where: {
                   !$0.supportedDepthDataFormats.isEmpty && CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1920
               }), let depthFormat = format.supportedDepthDataFormats.last {
                try device.lockForConfiguration()
                session.sessionPreset = .inputPriority
                device.activeFormat = format
                device.activeDepthDataFormat = depthFormat
                device.unlockForConfiguration()
            }
            session.addOutput(photoOutput)
            if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = true }
            let video = AVCaptureVideoDataOutput()
            video.alwaysDiscardsLateVideoFrames = true
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            video.setSampleBufferDelegate(self, queue: visionQueue)
            guard session.canAddOutput(video) else { throw CocoaError(.featureUnsupported) }
            session.addOutput(video)
            if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            session.commitConfiguration()
            session.startRunning()
            let hasDepth = photoOutput.isDepthDataDeliveryEnabled
            DispatchQueue.main.async {
                self.depthEnabled = hasDepth
                self.status = "Keep the whole body in frame, with arms slightly apart."
            }
        } catch {
            session.commitConfiguration()
            publish("Couldn't start camera: \(error.localizedDescription)")
        }
    }

    func capture() {
        isCapturing = true
        queue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            let codec: AVVideoCodecType = self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            settings.isDepthDataDeliveryEnabled = self.photoOutput.isDepthDataDeliveryEnabled
            settings.embedsDepthDataInPhoto = settings.isDepthDataDeliveryEnabled
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        DispatchQueue.main.async {
            self.isCapturing = false
            if let error { self.status = "Capture failed: \(error.localizedDescription)" }
            else if let data = photo.fileDataRepresentation() { self.onCapture?(data) }
            else { self.status = "No photo returned. Please try again." }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(time - lastDetection) >= 0.5,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastDetection = time
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
            let count = request.results?.filter { $0.confidence > 0.5 }.count ?? 0
            DispatchQueue.main.async { self.peopleCount = count }
        } catch {
            DispatchQueue.main.async {
                self.peopleCount = 0
                self.status = "Live detection unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func publish(_ message: String) { DispatchQueue.main.async { self.status = message } }
}

struct PersonCameraView: View {
    var onCapture: (Data) -> Void
    @StateObject private var controller = PersonCameraController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button("Close") { dismiss() }
                    Spacer()
                    Text(controller.depthEnabled ? "Photo + depth" : "Photo only").font(RallyStyle.font(12, .semibold))
                }
                .padding().background(RallyStyle.paper, in: Capsule())
                Spacer()
                Image(systemName: "figure.stand").font(.system(size: 150, weight: .ultraLight)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                VStack(spacing: 16) {
                    Text(controller.status).font(RallyStyle.font(14)).multilineTextAlignment(.center)
                    Text("\(controller.peopleCount) people detected").font(RallyStyle.font(18, .bold))
                        .foregroundStyle(controller.peopleCount > 0 ? RallyStyle.success : RallyStyle.muted)
                    Button(action: controller.capture) {
                        Label(controller.isCapturing ? "Capturing…" : "Capture person", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(PushButtonStyle())
                    .disabled(controller.peopleCount == 0 || controller.isCapturing)
                }
                .padding(20).background(RallyStyle.paper, in: RoundedRectangle(cornerRadius: 24))
            }
            .padding(24)
        }
        .background(.black).foregroundStyle(RallyStyle.ink).tint(RallyStyle.ink).preferredColorScheme(.light)
        .onAppear { controller.onCapture = onCapture; controller.start() }
        .onDisappear { controller.stop() }
    }
}

private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: CameraPreviewUIView, context: Context) {}
}
