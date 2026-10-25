import SwiftUI
import WebKit
import Security

struct CharacterJob: Codable {
    let id: String
    let status: String
    let stage: String
    let progress: Double
    let rigged: Bool
    let warning: String?
    let error: String?
    let credits: Double
}

struct CharacterAsset: Codable, Identifiable {
    var id: String
    var createdAt: Date
    var server: String
    var rigged = false
    var angles: [String: [Double]] = [:]
    var yaw: Double = 0
    var attribution: String?
    var editing: CharacterEditingSettings?

    static var root: URL { HouseStore.documents.appendingPathComponent("Characters3D", isDirectory: true) }
    var directory: URL { Self.root.appendingPathComponent(id, isDirectory: true) }
    var hasModel: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.glb").path) }
    var hasValidModel: Bool {
        let url = directory.appendingPathComponent("source.glb")
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 12), header.count == 12, header.prefix(4) == Data("glTF".utf8),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, (20...(100 * 1024 * 1024)).contains(size) else { return false }
        return header.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) == 2 &&
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) == size
        }
    }
    var preview: UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent("preview.png").path)
            ?? UIImage(contentsOfFile: directory.appendingPathComponent("input.png").path)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("character.json"), options: .atomic)
    }

    static func all() -> [CharacterAsset] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("character.json")),
                  let asset = try? JSONDecoder().decode(Self.self, from: data),
                  UUID(uuidString: asset.id) != nil, asset.id == folder.lastPathComponent else { return nil }
            return asset
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

struct CharacterAPI {
    let baseURL: URL
    let accessToken: String
    let session: URLSession

    init(address: String, accessToken: String, session: URLSession = .shared) throws {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else { throw CharacterFailure("Enter a valid 3D server address.") }
        let hostParts = host.split(separator: ".", omittingEmptySubsequences: false)
        let parts = hostParts.compactMap { Int($0) }
        let privateIP = hostParts.count == 4 && parts.count == 4 && parts.allSatisfy { (0...255).contains($0) } &&
            (parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])))
        let local = host == "localhost" || host == "[::1]" || host.hasSuffix(".local") || privateIP
        guard components.scheme == "https" || (components.scheme == "http" && local) else {
            throw CharacterFailure("Use HTTPS, or HTTP only for a trusted local development server.")
        }
        baseURL = url
        self.accessToken = accessToken
        self.session = session
    }

    func request(_ path: String, png: Data? = nil, id: String? = nil, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let png {
            request.httpMethod = "POST"
            request.httpBody = png
            request.setValue("image/png", forHTTPHeaderField: "Content-Type")
            request.setValue(id, forHTTPHeaderField: "X-Request-ID")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CharacterFailure("Invalid 3D server response.") }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw CharacterFailure((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "3D server request failed (\(response.statusCode)).")
        }
        return data
    }
}

struct CharacterFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CharacterBone: Decodable, Identifiable {
    let id: Int
    let name: String
    let limits: [[Double]]?

    var displayName: String {
        let shortName = name.components(separatedBy: CharacterSet(charactersIn: ":|")).last ?? name
        return shortName.replacingOccurrences(of: "^mixamorig[0-9]*[_:]?", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

/// Every character generation in flight, for the progress bar along the bottom of the screen.
/// Generations keep running when you leave their screen, so the bar is the one place they show.
@MainActor
final class CharacterBuilds: ObservableObject {
    static let shared = CharacterBuilds()
    @Published private(set) var progress: [String: Double] = [:]

    /// The least-advanced build, or nil when nothing is generating.
    var fraction: Double? { progress.values.min() }

    func update(_ id: String, _ value: Double) { progress[id] = max(progress[id] ?? 0, min(1, max(0.02, value))) }
    func finish(_ id: String) { progress[id] = nil }

    /// Mesh, rig check and rigging, weighted roughly by how long each takes.
    static func overall(_ job: CharacterJob) -> Double {
        let stage = min(1, max(0, job.progress / 100))
        switch job.status == "ready" ? "ready" : job.stage {
        case "ready": return 1
        case "checking": return 0.6 + 0.1 * stage
        case "rigging": return 0.7 + 0.3 * stage
        default: return 0.6 * stage
        }
    }
}

@MainActor
final class Character3DModel: ObservableObject {
    @Published var asset: CharacterAsset?
    @Published var modelData: Data?
    @Published var bones: [CharacterBone] = []
    @Published var selectedBone = 0
    @Published var selectedAxis = 0
    @Published var angles: [String: [Double]] = [:]
    @Published var yaw: Double = 0
    @Published var showsSkeleton = false
    @Published var busy = false
    @Published var exporting = false
    @Published var viewerLoaded = false
    @Published var status = "Turn a cutout into a textured 3D character."
    @Published var warning: String?
    @Published var error: String?
    @Published var saved = false
    @Published var editing = CharacterEditingSettings()
    @Published var supportsHumanoid = false
    @Published var undoCount = 0
    @Published var redoCount = 0
    @Published var cloneCount = 0
    @Published var showsWheel = false
    @Published var objectSelected = false
    @Published var roomName = "Practice room"
    var savedPaint: [String: Any]?
    var savedScene: [String: Any]?
    var onShot: (([String: Any]) -> Void)?
    var onTaunt: (() -> Void)?
    var onExport: ((Data, [[String: Any]]) -> Void)?
    weak var webView: WKWebView?
    var placementRevision = 0
    private var work: Task<Void, Never>?
    private let session: URLSession

    init(asset: CharacterAsset? = nil, session: URLSession = .shared) {
        self.asset = asset
        self.session = session
        if let asset {
            angles = asset.angles
            yaw = asset.yaw
            editing = asset.editing ?? CharacterEditingSettings()
            savedPaint = Self.readObject(asset.directory.appendingPathComponent("paint.json"))
            savedScene = Self.readObject(asset.directory.appendingPathComponent("scene.json"))
            modelData = try? Data(contentsOf: asset.directory.appendingPathComponent("source.glb"))
            if let data = try? Data(contentsOf: asset.directory.appendingPathComponent("generation.json")),
               let job = try? JSONDecoder().decode(CharacterJob.self, from: data) {
                warning = job.warning
            }
            status = modelData == nil ? "Generation can be resumed from this device." : "Drag to orbit. Pinch to zoom."
        }
    }

    func generate(png: Data, attribution: String?, asProfile: Bool = false) {
        guard !busy, asset == nil else { return }
        do {
            let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: HostedCharacterService.address, attribution: attribution)
            try asset.save()
            try png.write(to: asset.directory.appendingPathComponent("input.png"), options: .atomic)
            if let attribution { try Data(attribution.utf8).write(to: asset.directory.appendingPathComponent("ATTRIBUTION.txt")) }
            self.asset = asset
            if asProfile { CharacterProfile.remember(asset) }
            resume()
        } catch { self.error = error.localizedDescription }
    }

    func resume() {
        guard !busy, let asset else { return }
        busy = true
        error = nil
        // Keyed per model, so a screen handing the job to another model can't erase its entry.
        let key = "\(asset.id)/\(ObjectIdentifier(self).hashValue)"
        CharacterBuilds.shared.update(key, 0)
        work = Task {
            defer { busy = false; CharacterBuilds.shared.finish(key) }
            do {
                let api = try HostedCharacterService.api(session: session)
                let input = try Data(contentsOf: asset.directory.appendingPathComponent("input.png"))
                let initial = try await api.request("characters", png: input, id: asset.id, headers: ["X-Rig": "1"])
                var job = try JSONDecoder().decode(CharacterJob.self, from: initial)
                while true {
                    try Task.checkCancellation()
                    status = "\(job.stage.capitalized) · \(Int(job.progress))%"
                    CharacterBuilds.shared.update(key, CharacterBuilds.overall(job))
                    if job.status == "failed" { throw CharacterFailure(job.error ?? "Tripo could not build this character.") }
                    if job.status == "ready" { break }
                    try await Task.sleep(for: .seconds(3))
                    let data = try await api.request("characters/\(asset.id)")
                    job = try JSONDecoder().decode(CharacterJob.self, from: data)
                }
                status = "Downloading your 3D character…"
                let data = try await api.request("characters/\(asset.id)/model")
                guard data.count >= 12, data.count <= 100 * 1024 * 1024,
                      data.prefix(4) == Data("glTF".utf8) else { throw CharacterFailure("The server did not return a supported GLB model.") }
                try data.write(to: asset.directory.appendingPathComponent("source.glb"), options: .atomic)
                try JSONEncoder().encode(job).write(to: asset.directory.appendingPathComponent("generation.json"), options: .atomic)
                self.asset?.rigged = job.rigged
                try self.asset?.save()
                modelData = data
                warning = job.warning
                status = "Drag to orbit. Pinch to zoom."
            } catch is CancellationError {
                status = "Paused locally. Tripo continues on the server; reopen this character to resume."
            } catch { self.error = error.localizedDescription }
        }
    }

    func stopPolling() { work?.cancel() }

    var currentAngle: Double { angles[String(selectedBone)]?[selectedAxis] ?? 0 }
    var angleRange: ClosedRange<Double> {
        let limits = bones.first(where: { $0.id == selectedBone })?.limits
        guard let limits, limits.indices.contains(selectedAxis), limits[selectedAxis].count == 2 else { return -90...90 }
        return limits[selectedAxis][0]...max(limits[selectedAxis][0] + 0.01, limits[selectedAxis][1])
    }

    func setAngle(_ angle: Double) {
        guard !editing.frozen, editing.placementLocked != true else { return }
        var values = angles[String(selectedBone)] ?? [0, 0, 0]
        values[selectedAxis] = min(angleRange.upperBound, max(angleRange.lowerBound, angle))
        angles[String(selectedBone)] = values
        saved = false
    }

    func selectPose(_ id: String) {
        guard !editing.frozen, editing.placementLocked != true else { return }
        angles = [:]
        editing.preset = id
        showsWheel = false
        saved = false
    }

    func command(_ name: String) {
        Task {
            do { _ = try await webView?.callAsyncJavaScript("window.characterViewer.action(name)", arguments: ["name": name], in: nil, contentWorld: .page) }
            catch { self.error = "Could not complete the editor action." }
        }
    }

    func preparePainting(againstWall: Bool = false) {
        guard viewerLoaded else { return }
        let unplaced = !editing.room && abs(editing.position[0]) < 0.0001 && abs(editing.position[2]) < 0.0001 && editing.rotation == [0, 0, 0, 1]
        editing.room = true
        Task {
            do {
                _ = try await webView?.callAsyncJavaScript("window.characterViewer.configure(editing, angles, yaw, skeleton, true, revision); return window.characterViewer.paintBackground(attach, movable)",
                    arguments: ["editing": editing.dictionary, "angles": angles, "yaw": yaw, "skeleton": showsSkeleton, "revision": placementRevision,
                        "attach": againstWall || unplaced, "movable": !editing.frozen && editing.placementLocked != true], in: nil, contentWorld: .page)
            } catch { self.error = "Could not show the painting background." }
        }
    }

    func lockPlacement() {
        guard viewerLoaded else { return }
        editing.placementLocked = true
        editing.frozen = false
        showsSkeleton = false
        showsWheel = false
        editing.tool = "paint"
        preparePainting()
    }

    func unlockPlacement() {
        editing.placementLocked = false
        editing.frozen = false
        editing.room = true
        editing.tool = "orbit"
        if viewerLoaded { command("roomView") }
    }

    static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func export() {
        guard viewerLoaded, !exporting else { return }
        exporting = true
        error = nil
        Task {
            do {
                _ = try await webView?.callAsyncJavaScript("window.characterViewer.configure(editing, angles, yaw, skeleton, true, revision); await window.characterViewer.exportModel()",
                    arguments: ["editing": editing.dictionary, "angles": angles, "yaw": yaw, "skeleton": showsSkeleton, "revision": placementRevision], in: nil, contentWorld: .page)
            } catch { exporting = false; self.error = "Could not export the 3D character." }
        }
    }

    func receiveExport(model: String, thumbnail: String, paint: [String: Any]? = nil, scene: [String: Any]? = nil, boxes: [[String: Any]] = []) {
        defer { exporting = false }
        do {
            guard var asset, let model = Data(base64Encoded: model), let preview = Data(base64Encoded: thumbnail) else {
                throw CharacterFailure("Could not read the exported character.")
            }
            try model.write(to: asset.directory.appendingPathComponent("character.glb"), options: .atomic)
            try preview.write(to: asset.directory.appendingPathComponent("preview.png"), options: .atomic)
            if let paint {
                try JSONSerialization.data(withJSONObject: paint).write(to: asset.directory.appendingPathComponent("paint.json"), options: .atomic)
                savedPaint = paint
            }
            if let scene {
                try JSONSerialization.data(withJSONObject: scene).write(to: asset.directory.appendingPathComponent("scene.json"), options: .atomic)
                savedScene = scene
            }
            asset.angles = angles
            asset.yaw = yaw
            asset.editing = editing
            try asset.save()
            self.asset = asset
            saved = true
            status = "Saved 3D mesh and pose. Reopen it from Studio."
            onExport?(model, boxes)
        } catch { self.error = error.localizedDescription }
    }
}

struct CharacterBodyArchive: Codable {
    struct Pose: Codable {
        let id: String
        let name: String
        let icon: String
    }
    struct Info: Codable {
        let vertexCount: Int
        let triangleCount: Int
        let poses: [Pose]
    }
    let info: Info
    let data: Data
    /// Optional for older peers; preserves the unpainted appearance for the seeker's reveal.
    var originalTexture: Data? = nil

    var isValid: Bool {
        let vertices = info.vertexCount, triangles = info.triangleCount
        guard (1...150000).contains(vertices), (1...100000).contains(triangles),
              (1...16).contains(info.poses.count), Set(info.poses.map(\.id)).count == info.poses.count,
              data.count == vertices * 8 + triangles * 12 + info.poses.count * vertices * 12 else { return false }
        let indexStart = vertices * 8, positionStart = indexStart + triangles * 12
        return data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: indexStart, by: 4) {
                if !Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))).isFinite { return false }
            }
            for offset in stride(from: indexStart, to: positionStart, by: 4) {
                if UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) >= vertices { return false }
            }
            for offset in stride(from: positionStart, to: data.count, by: 4) {
                let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                if !value.isFinite || abs(value) > 100 { return false }
            }
            return true
        }
    }

    static func load(from directory: URL) -> Self? {
        guard let info = try? JSONDecoder().decode(Info.self, from: Data(contentsOf: directory.appendingPathComponent("body.json"))),
              let data = try? Data(contentsOf: directory.appendingPathComponent("body.bin")), data.count <= 40 * 1024 * 1024 else { return nil }
        let archive = Self(info: info, data: data)
        return archive.isValid ? archive : nil
    }
}

enum CharacterProfile {
    static let preferenceKey = "personalCharacterID"

    static func candidate(assets: [CharacterAsset] = CharacterAsset.all(), defaults: UserDefaults = .standard) -> CharacterAsset? {
        if let id = defaults.string(forKey: preferenceKey), let saved = assets.first(where: { $0.id == id }) { return saved }
        return assets.first { $0.rigged && $0.hasModel && $0.attribution == nil }
    }

    static var ready: CharacterAsset? {
        guard let asset = candidate(), isReady(asset) else { return nil }
        return asset
    }

    static func isReady(_ asset: CharacterAsset) -> Bool {
        asset.rigged && asset.hasValidModel && CharacterBodyArchive.load(from: asset.directory) != nil &&
            UIImage(contentsOfFile: asset.directory.appendingPathComponent("body-texture.png").path) != nil
    }

    static func remember(_ asset: CharacterAsset, defaults: UserDefaults = .standard) {
        defaults.set(asset.id, forKey: preferenceKey)
    }

    static func saveBody(_ result: [String: Any], for asset: CharacterAsset) throws {
        guard asset.rigged, let object = result["info"], let encoded = result["data"] as? String,
              let data = Data(base64Encoded: encoded), let texture = result["texture"] as? String,
              let png = Data(base64Encoded: texture), UIImage(data: png) != nil else {
            throw CharacterFailure("The rigged character could not be prepared. Try loading it again.")
        }
        let info = try JSONDecoder().decode(CharacterBodyArchive.Info.self, from: JSONSerialization.data(withJSONObject: object))
        guard CharacterBodyArchive(info: info, data: data).isValid else { throw CharacterFailure("The character contains unsupported body geometry.") }
        try data.write(to: asset.directory.appendingPathComponent("body.bin"), options: .atomic)
        try JSONEncoder().encode(info).write(to: asset.directory.appendingPathComponent("body.json"), options: .atomic)
        try png.write(to: asset.directory.appendingPathComponent("body-texture.png"), options: .atomic)
        remember(asset)
    }
}

/// The 3D service both apps always use: the production Vercel deployment (server/lib/characters.mjs).
/// It cannot be changed in the apps. The token is that deployment's TRIPO_PROXY_TOKEN, never the
/// Tripo API key; the server's daily generation limit caps its use.
enum HostedCharacterService {
    static let address = "https://mecha-soonelians.vercel.app"
    static let token = "78d80f57ee21bc84260f6a528c94cbf92832f1fb6b25bdb34546dd91385575a7"

    static func api(session: URLSession = .shared) throws -> CharacterAPI {
        try CharacterAPI(address: address, accessToken: token, session: session)
    }
}
