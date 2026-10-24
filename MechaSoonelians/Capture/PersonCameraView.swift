import AVFoundation
import SwiftUI
import Vision

@MainActor
final class PersonCaptureTimer: ObservableObject {
    @Published private(set) var secondsRemaining: Int?
    private var work: Task<Void, Never>?
    private let waitOneSecond: @Sendable () async throws -> Void

    init(waitOneSecond: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.waitOneSecond = waitOneSecond
    }

    func start(capture: @escaping @MainActor () -> Void) {
        guard secondsRemaining == nil else { return }
        secondsRemaining = 5
        work = Task { [weak self] in
            guard let self else { return }
            do {
                for seconds in stride(from: 4, through: 0, by: -1) {
                    try await waitOneSecond()
                    try Task.checkCancellation()
                    if seconds == 0 {
                        secondsRemaining = nil
                        work = nil
                        capture()
                    } else {
                        secondsRemaining = seconds
                    }
                }
            } catch {
                if !Task.isCancelled { secondsRemaining = nil; work = nil }
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        secondsRemaining = nil
    }
}

final class PersonCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var status = "Starting camera…"
    @Published var peopleCount = 0
    @Published var isCapturing = false
    @Published var depthEnabled = false
    @Published private(set) var isReady = false
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
        isReady = false
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() {
        guard wantsRunning else { return }
        // Selfie: the front TrueDepth camera still gives depth on Face ID phones.
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            publish("No camera available. Import a photo instead.")
            return
        }
        do {
            session.beginConfiguration()
            session.sessionPreset = .photo
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(photoOutput) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
            if device.deviceType == .builtInTrueDepthCamera,
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
            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                // Save the selfie as it looked in the (mirrored) preview.
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
            session.commitConfiguration()
            session.startRunning()
            let hasDepth = photoOutput.isDepthDataDeliveryEnabled
            DispatchQueue.main.async {
                self.isReady = true
                self.depthEnabled = hasDepth
                self.status = "Prop your phone up and step back so your whole body is in frame, arms slightly apart."
            }
        } catch {
            session.commitConfiguration()
            publish("Couldn't start camera: \(error.localizedDescription)")
        }
    }

    func capture() {
        guard isReady, !isCapturing else { return }
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
    @StateObject private var timer = PersonCaptureTimer()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button("Close") { timer.cancel(); dismiss() }
                    Spacer()
                    Text(controller.depthEnabled ? "Photo + depth" : "Photo only").font(RallyStyle.font(12, .semibold))
                }
                .padding().background(RallyStyle.paper, in: Capsule())
                Spacer()
                if let seconds = timer.secondsRemaining {
                    Text("\(seconds)")
                        .font(RallyStyle.font(140, .heavy)).monospacedDigit()
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 12)
                        .accessibilityLabel("Photo in \(seconds) seconds")
                        .accessibilityIdentifier("selfieCountdown")
                } else {
                    Image(systemName: "figure.stand").font(.system(size: 150, weight: .ultraLight)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                VStack(spacing: 16) {
                    Text(controller.status).font(RallyStyle.font(14)).multilineTextAlignment(.center)
                    Text("\(controller.peopleCount) people detected").font(RallyStyle.font(18, .bold))
                        .foregroundStyle(controller.peopleCount > 0 ? RallyStyle.success : RallyStyle.muted)
                    Text("Tap the 5-second timer, then step back with your whole body in frame.")
                        .font(RallyStyle.font(12)).multilineTextAlignment(.center)
                    Button {
                        if timer.secondsRemaining != nil { timer.cancel() }
                        else { timer.start { controller.capture() } }
                    } label: {
                        Label(timer.secondsRemaining != nil ? "Cancel timer" : controller.isCapturing ? "Capturing…" : "Take selfie · 5s",
                              systemImage: timer.secondsRemaining != nil ? "xmark" : "timer")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(PushButtonStyle())
                    .disabled(!controller.isReady || controller.isCapturing)
                    .accessibilityIdentifier("selfieTimerButton")
                }
                .padding(20).background(RallyStyle.paper, in: RoundedRectangle(cornerRadius: 24))
            }
            .padding(24)
        }
        .background(.black).foregroundStyle(RallyStyle.ink).tint(RallyStyle.ink).preferredColorScheme(.light)
        .onAppear { controller.onCapture = onCapture; controller.start() }
        .onDisappear { timer.cancel(); controller.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { timer.cancel() } }
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
