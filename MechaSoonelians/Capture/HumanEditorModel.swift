import SwiftUI

@MainActor
final class HumanEditorModel: ObservableObject {
    @Published var photo: UIImage?
    @Published var depth: CaptureDepth?
    @Published var humans: [HumanDetection] = []
    @Published var selectedID: Int?
    @Published var angles: [String: Double] = [:]
    @Published var selectedBone = "leftUpperArm"
    @Published var isProcessing = false
    @Published var status = "Finding people…"
    @Published var message: String?
    @Published var isSample = true
    @Published var usesSampleAnalysis = false
    let poseScene = HumanPoseScene(size: CGSize(width: 640, height: 640))
    private var generation = UUID()
    private var originalData: Data?

    var selectedHuman: HumanDetection? { humans.first { $0.id == selectedID } }
    var bones: [RigBone] { poseScene.rig?.bones ?? [] }
    var canPose: Bool { selectedHuman != nil && !bones.isEmpty && !isProcessing }

    func loadSample() async {
        guard let photoURL = Bundle.main.url(forResource: "human-rgb", withExtension: "png"),
              let photo = UIImage(contentsOfFile: photoURL.path) else {
            status = "The human sample could not be loaded. Choose a photo instead."
            return
        }
        var depth: CaptureDepth?
        if let url = Bundle.main.url(forResource: "human-depth-float32", withExtension: "bin"),
           let values = try? Data(contentsOf: url) {
            depth = CaptureDepth.from(values: values, width: 640, height: 480, metric: true)
        }
        await load(CaptureImage(image: photo, depth: depth), sample: true)
    }

    func load(_ capture: CaptureImage, sample: Bool = false) async {
        let currentGeneration = UUID()
        generation = currentGeneration
        photo = capture.image
        depth = capture.depth
        originalData = capture.originalData
        isSample = sample
        usesSampleAnalysis = false
        humans = []
        selectedID = nil
        angles = [:]
        isProcessing = true
        status = "Detecting people, removing backgrounds, and finding joints…"
        guard let image = capture.image.cgImage else {
            status = "Couldn't read the image."
            isProcessing = false
            return
        }
        do {
            let detections = try await Task.detached(priority: .userInitiated) { try HumanAnalyzer.analyze(image) }.value
            guard generation == currentGeneration, !Task.isCancelled else { return }
            humans = detections
        } catch {
            guard generation == currentGeneration, !Task.isCancelled else { return }
            if sample, let cached = cachedSample() {
                humans = cached
                usesSampleAnalysis = true
            } else {
                status = "Human detection failed. Try a clear, well-lit photo. \(error.localizedDescription)"
                isProcessing = false
                return
            }
        }
        isProcessing = false
        if let first = humans.first {
            select(first.id)
            status = "\(humans.count) people found. Select the person you want to edit."
        } else {
            status = "No person found. Try a photo with the whole body visible."
        }
    }

    func select(_ id: Int) {
        guard let human = humans.first(where: { $0.id == id }) else { return }
        selectedID = id
        angles = [:]
        let imageSize = CGSize(width: human.cutout.width, height: human.cutout.height)
        let bounds = human.bounds.insetBy(dx: -0.04, dy: -0.04).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rectangle = CGRect(x: bounds.minX * imageSize.width, y: bounds.minY * imageSize.height,
                               width: bounds.width * imageSize.width, height: bounds.height * imageSize.height).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard let cropped = human.cutout.cropping(to: rectangle) else { return }
        let joints = human.joints.map { joint in
            BodyJoint(name: joint.name, point: CGPoint(
                x: (joint.point.x * imageSize.width - rectangle.minX) / rectangle.width,
                y: (joint.point.y * imageSize.height - rectangle.minY) / rectangle.height
            ), confidence: joint.confidence)
        }
        poseScene.configure(image: cropped, joints: joints)
        selectedBone = bones.first(where: { $0.id.hasSuffix("UpperArm") })?.id ?? bones.first?.id ?? "spine"
    }

    func preset(wave: Bool) {
        guard let rig = poseScene.rig else { return }
        angles = [:]
        let points = rig.points
        var waved = false
        for side in ["left", "right"] {
            guard let shoulder = points[side + "Shoulder"], let elbow = points[side + "Elbow"],
                  let wrist = points[side + "Wrist"], let neck = points["neck"] else { continue }
            if wave && waved { continue }
            let facesRight = shoulder.x >= neck.x
            let target = wave ? (facesRight ? -Double.pi / 3 : -2 * Double.pi / 3) : (facesRight ? 0 : Double.pi)
            let original = atan2(elbow.y - shoulder.y, elbow.x - shoulder.x)
            let upper = normalizedDegrees((target - original) * 180 / .pi)
            angles[side + "UpperArm"] = upper
            let forearmTarget = wave ? -Double.pi / 2 : target
            let originalForearm = atan2(wrist.y - elbow.y, wrist.x - elbow.x)
            angles[side + "Forearm"] = normalizedDegrees((forearmTarget - originalForearm) * 180 / .pi - upper)
            waved = true
        }
    }

    func save() {
        guard let human = selectedHuman, let photo else { return }
        do {
            let root = HouseStore.documents.appendingPathComponent("Players", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let temporary = root.appendingPathComponent(".saving-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let assets: [(String, UIImage)] = [
                ("photo.png", photo), ("cutout.png", UIImage(cgImage: human.cutout)), ("mask.png", UIImage(cgImage: human.mask))
            ]
            for (name, image) in assets {
                guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: temporary.appendingPathComponent(name))
            }
            if let originalData { try originalData.write(to: temporary.appendingPathComponent("original.image")) }
            if isSample {
                for (name, extensionName) in [("ATTRIBUTION", "txt"), ("human-depth-metadata", "json")] {
                    if let source = Bundle.main.url(forResource: name, withExtension: extensionName) {
                        try FileManager.default.copyItem(at: source, to: temporary.appendingPathComponent("\(name).\(extensionName)"))
                    }
                }
            }
            var metadata: [String: Any] = [
                "version": 1, "rigType": "2d-rigid-body-parts", "personID": human.id,
                "imageWidth": photo.cgImage?.width ?? 0, "imageHeight": photo.cgImage?.height ?? 0,
                "jointCoordinates": "normalized original image, top-left origin, x right, y down",
                "anglesDegrees": angles, "usesCachedSampleAnalysis": usesSampleAnalysis,
                "sampleSource": isSample ? "TUM RGB-D fr3/walking_static, CC BY 4.0" : "User capture",
                "crop": [human.bounds.minX, human.bounds.minY, human.bounds.width, human.bounds.height],
                "joints": human.joints.map { ["name": $0.name, "x": $0.point.x, "y": $0.point.y, "confidence": $0.confidence] as [String: Any] }
            ]
            if canPose {
                guard let posed = poseScene.exportImage()?.pngData() else { throw CocoaError(.fileWriteUnknown) }
                try posed.write(to: temporary.appendingPathComponent("posed.png"))
            }
            if let depth {
                try depth.values.write(to: temporary.appendingPathComponent("depth-float32.bin"))
                metadata["depth"] = ["width": depth.width, "height": depth.height, "encoding": "little-endian Float32",
                                     "units": depth.metric ? "meters" : "relative", "space": "original unposed capture"]
            }
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: temporary.appendingPathComponent("rig.json"))
            try FileManager.default.moveItem(at: temporary, to: folder)
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Rally"
            message = "Saved cutout, mask, pose, and available depth in Files › \(appName) › Players."
        } catch {
            message = "Couldn't save the player: \(error.localizedDescription)"
        }
    }

    func make3DCutout() -> Data? {
        guard let human = selectedHuman else { return nil }
        let bounds = human.bounds.insetBy(dx: -0.02, dy: -0.02).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rectangle = CGRect(x: bounds.minX * CGFloat(human.cutout.width), y: bounds.minY * CGFloat(human.cutout.height),
                               width: bounds.width * CGFloat(human.cutout.width), height: bounds.height * CGFloat(human.cutout.height)).integral
        guard let cropped = human.cutout.cropping(to: rectangle) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let side: CGFloat = 1024
        let scale = (side - 64) / CGFloat(max(cropped.width, cropped.height))
        let size = CGSize(width: CGFloat(cropped.width) * scale, height: CGFloat(cropped.height) * scale)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }

    private func normalizedDegrees(_ angle: Double) -> Double {
        var result = angle.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }

    private func cachedSample() -> [HumanDetection]? {
        guard let url = Bundle.main.url(forResource: "human-analysis", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode([HumanSampleMetadata].self, from: data) else { return nil }
        let detections = metadata.compactMap { person -> HumanDetection? in
            guard let cutout = UIImage(named: "human-\(person.id)-cutout.png")?.cgImage,
                  let mask = UIImage(named: "human-\(person.id)-mask.png")?.cgImage else { return nil }
            return HumanDetection(id: person.id, bounds: person.bounds, joints: person.joints, cutout: cutout, mask: mask)
        }
        return detections.isEmpty ? nil : detections
    }
}
