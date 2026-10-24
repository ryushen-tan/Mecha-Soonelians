import SwiftUI
import WebKit

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

    static var root: URL { HouseStore.documents.appendingPathComponent("Characters3D", isDirectory: true) }
    var directory: URL { Self.root.appendingPathComponent(id, isDirectory: true) }
    var hasModel: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.glb").path) }
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

    init(address: String, accessToken: String) throws {
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
    }

    func request(_ path: String, png: Data? = nil, id: String? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let png {
            request.httpMethod = "POST"
            request.httpBody = png
            request.setValue("image/png", forHTTPHeaderField: "Content-Type")
            request.setValue(id, forHTTPHeaderField: "X-Request-ID")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
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
    weak var webView: WKWebView?
    private var work: Task<Void, Never>?

    init(asset: CharacterAsset? = nil) {
        self.asset = asset
        if let asset {
            angles = asset.angles
            yaw = asset.yaw
            modelData = try? Data(contentsOf: asset.directory.appendingPathComponent("source.glb"))
            if let data = try? Data(contentsOf: asset.directory.appendingPathComponent("generation.json")),
               let job = try? JSONDecoder().decode(CharacterJob.self, from: data) {
                warning = job.warning
            }
            status = modelData == nil ? "Generation can be resumed from this device." : "Drag to orbit. Pinch to zoom."
        }
    }

    func generate(png: Data, address: String, token: String, attribution: String?) {
        guard !busy, asset == nil else { return }
        do {
            _ = try CharacterAPI(address: address, accessToken: token)
            let asset = CharacterAsset(id: UUID().uuidString, createdAt: Date(), server: address, attribution: attribution)
            try asset.save()
            try png.write(to: asset.directory.appendingPathComponent("input.png"), options: .atomic)
            if let attribution { try Data(attribution.utf8).write(to: asset.directory.appendingPathComponent("ATTRIBUTION.txt")) }
            self.asset = asset
            resume(token: token)
        } catch { self.error = error.localizedDescription }
    }

    func resume(token: String) {
        guard !busy, let asset else { return }
        busy = true
        error = nil
        work = Task {
            defer { busy = false }
            do {
                let api = try CharacterAPI(address: asset.server, accessToken: token)
                let input = try Data(contentsOf: asset.directory.appendingPathComponent("input.png"))
                let initial = try await api.request("characters", png: input, id: asset.id)
                var job = try JSONDecoder().decode(CharacterJob.self, from: initial)
                while true {
                    try Task.checkCancellation()
                    status = "\(job.stage.capitalized) · \(Int(job.progress))%"
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

    func setAngle(_ angle: Double) {
        var values = angles[String(selectedBone)] ?? [0, 0, 0]
        values[selectedAxis] = angle
        angles[String(selectedBone)] = values
        saved = false
    }

    func export() {
        guard viewerLoaded, !exporting else { return }
        exporting = true
        error = nil
        Task {
            do {
                _ = try await webView?.callAsyncJavaScript("window.characterViewer.pose(angles, yaw, skeleton); await window.characterViewer.exportModel()",
                    arguments: ["angles": angles, "yaw": yaw, "skeleton": showsSkeleton], in: nil, contentWorld: .page)
            } catch { exporting = false; self.error = "Could not export the 3D character." }
        }
    }

    func receiveExport(model: String, thumbnail: String) {
        defer { exporting = false }
        do {
            guard var asset, let model = Data(base64Encoded: model), let preview = Data(base64Encoded: thumbnail) else {
                throw CharacterFailure("Could not read the exported character.")
            }
            try model.write(to: asset.directory.appendingPathComponent("character.glb"), options: .atomic)
            try preview.write(to: asset.directory.appendingPathComponent("preview.png"), options: .atomic)
            asset.angles = angles
            asset.yaw = yaw
            try asset.save()
            self.asset = asset
            saved = true
            status = "Saved 3D mesh and pose. Reopen it from Studio."
        } catch { self.error = error.localizedDescription }
    }
}
