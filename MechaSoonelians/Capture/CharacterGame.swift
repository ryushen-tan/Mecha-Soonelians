import SwiftUI
import WebKit
import AudioToolbox

struct GameConnection: Equatable {
    let server: URL
    let code: String
    let memberID: String
    let token: String
    let isHost: Bool
}

private struct GameConnectionKey: EnvironmentKey { static let defaultValue: GameConnection? = nil }
extension EnvironmentValues {
    var gameConnection: GameConnection? {
        get { self[GameConnectionKey.self] }
        set { self[GameConnectionKey.self] = newValue }
    }
}

struct GameSnapshot: Decodable {
    struct Visible: Decodable { let id: String; let version: String; let offset: [Double]? }
    struct Bounds: Decodable { let min: [Double]; let max: [Double] }
    struct Eject: Decodable { let available: Bool; let used: Bool; let bounds: Bounds? }
    struct Score: Decodable, Identifiable { let id: String; let name: String; let points: Int; let found: Bool }
    struct Hint: Decodable { let id: String; let at: Double; let position: [Double] }
    let mode: String
    let phase: String
    let remaining: Int
    let role: String
    let winner: String?
    let targetID: String?
    let published: [String]
    let visible: [Visible]
    let scores: [Score]
    let taunts: [Hint]
    let room: GameRoomGeometry?
    let eject: Eject?

    var isWaitingToHunt: Bool { phase == "preparation" && role == "hunter" }
}

@MainActor
final class CharacterGameModel: ObservableObject {
    @Published var snapshot: GameSnapshot?
    @Published var message = "Publish a disguise, then let the host start a round."
    @Published var error: String?
    @Published var busy = false
    @Published var practiceRemaining: Int?
    @Published var practiceScore = 0
    private var connection: GameConnection?
    private weak var editor: Character3DModel?
    private var polling: Task<Void, Never>?
    private var loaded: [String: String] = [:]
    private var publishing = false
    private var lastHint: Double = 0
    private var loadedRoom: Data?
    private var huntCameraStarted = false
    private var loadedOwnVersion: String?

    func connect(_ connection: GameConnection?, editor: Character3DModel) {
        stop()
        self.connection = connection
        loaded = [:]; loadedRoom = nil; huntCameraStarted = false; loadedOwnVersion = nil
        self.editor = editor
        Task { _ = try? await editor.webView?.callAsyncJavaScript("window.characterViewer.owner(id)", arguments: ["id": connection?.memberID ?? "practice"], in: nil, contentWorld: .page) }
        editor.onShot = { [weak self] ray in self?.shot(ray) }
        editor.onTaunt = { [weak self] in self?.taunt() }
        editor.onExport = { [weak self] data, _ in
            guard let self, self.publishing else { return }
            self.publishing = false
            Task { await self.publish(data) }
        }
        guard connection != nil else { message = "Solo practice. Join a Rally room for multiplayer rounds."; return }
        polling = Task {
            while !Task.isCancelled {
                do { try await refresh(); try await Task.sleep(for: .seconds(1)) }
                catch is CancellationError { break }
                catch { self.error = error.localizedDescription; try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }

    func stop() { polling?.cancel(); polling = nil }

    private func request(_ suffix: String, body: [String: Any]? = nil, model: Data? = nil) async throws -> Data {
        guard let connection else { throw CharacterFailure("Join a Rally room first.") }
        var request = URLRequest(url: connection.server.appendingPathComponent("rooms/\(connection.code)/\(suffix)"))
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let model {
            request.httpMethod = "POST"; request.httpBody = model
            request.setValue("model/gltf-binary", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw CharacterFailure(value?["error"] as? String ?? "Could not reach the game server.")
        }
        return data
    }

    private func accept(_ data: Data) throws {
        struct Response: Decodable { let game: GameSnapshot }
        snapshot = try JSONDecoder().decode(Response.self, from: data).game
        error = nil
    }

    private func refresh() async throws {
        var camera: [String: Any]?
        if snapshot?.phase == "hunting", ["hunter", "dual"].contains(snapshot?.role ?? ""), editor?.viewerLoaded == true {
            camera = try await editor?.webView?.callAsyncJavaScript("return window.characterViewer.viewRay()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            camera?["action"] = "view"
        }
        try accept(try await request("game", body: camera))
        guard let snapshot, let connection, let editor, editor.viewerLoaded, let view = editor.webView else { return }
        view.isUserInteractionEnabled = !snapshot.isWaitingToHunt
        if snapshot.isWaitingToHunt { view.resignFirstResponder() }
        _ = try await view.callAsyncJavaScript("window.characterViewer.huntLock(locked)", arguments: ["locked": snapshot.phase == "hunting" || snapshot.isWaitingToHunt], in: nil, contentWorld: .page)
        _ = try await view.callAsyncJavaScript("window.characterViewer.owner(id)", arguments: ["id": connection.memberID], in: nil, contentWorld: .page)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let room = snapshot.room, let data = try? encoder.encode(room), data != loadedRoom,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            _ = try await view.callAsyncJavaScript("window.characterViewer.setRoom(room)", arguments: ["room": object], in: nil, contentWorld: .page)
            loadedRoom = data
        }
        if snapshot.phase == "hunting", ["hunter", "dual"].contains(snapshot.role) {
            editor.editing.room = true
            editor.editing.tool = "tag"
            if !huntCameraStarted {
                _ = try await view.callAsyncJavaScript("window.characterViewer.beginHunt()", arguments: [:], in: nil, contentWorld: .page)
                huntCameraStarted = true
            }
        } else { huntCameraStarted = false }
        for owner in snapshot.visible where owner.id != connection.memberID && loaded[owner.id] != owner.version {
            let data = try await request("disguise/\(owner.id)")
            _ = try await view.callAsyncJavaScript("await window.characterViewer.remote(id, data, offset)", arguments: ["id": owner.id, "data": data.base64EncodedString(), "offset": owner.offset ?? [0, 0, 0]], in: nil, contentWorld: .page)
            loaded[owner.id] = owner.version
        }
        if snapshot.phase == "hunting", let own = snapshot.visible.first(where: { $0.id == connection.memberID }),
           own.version != loadedOwnVersion, let bounds = snapshot.eject?.bounds {
            _ = try await view.callAsyncJavaScript("window.characterViewer.relocateTo(bounds, frame)", arguments: ["bounds": ["min": bounds.min, "max": bounds.max], "frame": snapshot.role == "hider"], in: nil, contentWorld: .page)
            loadedOwnVersion = own.version
        }
        let found = snapshot.scores.first(where: { $0.id == connection.memberID })?.found ?? false
        let showOwn = !snapshot.isWaitingToHunt && (snapshot.phase != "hunting" || (!found && !["hunter", "dual"].contains(snapshot.role)))
        _ = try await view.callAsyncJavaScript("window.characterViewer.visibility(ids, own)", arguments: ["ids": snapshot.visible.map(\.id), "own": showOwn], in: nil, contentWorld: .page)
        if let hint = snapshot.taunts.max(by: { $0.at < $1.at }), hint.at > lastHint {
            lastHint = hint.at
            AudioServicesPlaySystemSound(1057)
            message = "A hider whistled nearby."
        }
        if snapshot.phase == "preparation" && snapshot.role == "hunter" { message = "Wait while the hiders prepare their disguises." }
        if snapshot.phase == "hunting" && ["hunter", "dual"].contains(snapshot.role) { message = "Tap a suspicious disguise to tag it. Drag to look; use the arrows to walk." }
        if snapshot.phase == "finished" { message = "Round finished. Winner: \(snapshot.winner ?? "tie")" }
    }

    func publishCurrent() {
        guard !busy, let editor else { return }
        guard snapshot?.isWaitingToHunt != true else { error = "Wait until the hiding phase ends."; return }
        guard snapshot?.phase != "hunting" else { error = "Disguises are locked during the hunt."; return }
        guard editor.editing.placementLocked == true else { error = "Lock your position and pose before publishing."; return }
        publishing = true
        busy = true
        message = "Saving and publishing your disguise…"
        editor.export()
    }

    func exportFailed() {
        if publishing { publishing = false; busy = false; error = editor?.error ?? "Could not publish this disguise." }
    }

    private func publish(_ data: Data) async {
        defer { busy = false }
        do { try accept(try await request("disguise", model: data)); message = "Disguise published to this room." }
        catch { self.error = error.localizedDescription }
    }

    func start(mode: String, preparation: Int, hunt: Int, autoTaunt: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let room = try await editor?.webView?.callAsyncJavaScript("return window.characterViewer.roomGeometry()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
                try accept(try await request("game", body: ["action": "start", "mode": mode, "preparationSeconds": preparation,
                    "huntSeconds": hunt, "autoTauntSeconds": autoTaunt ? 30 : 0, "room": room]))
                editor?.editing.room = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func shot(_ ray: [String: Any]) {
        Task {
            do {
                if connection == nil {
                    guard practiceRemaining != nil, let editor else { return }
                    let hit = try await editor.webView?.callAsyncJavaScript("return window.characterViewer.practiceTag(origin, direction)", arguments: ray, in: nil, contentWorld: .page) as? Bool ?? false
                    if hit { practiceScore += 500; message = "Disguise found! +500" }
                } else {
                    var body = ray; body["action"] = "shoot"
                    let data = try await request("game", body: body)
                    try accept(data)
                    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let result = value?["result"] as? [String: Any]
                    message = result?["hit"] as? Bool == true ? "Disguise found! +500" : "No disguise hit."
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func taunt() {
        guard connection != nil else { AudioServicesPlaySystemSound(1057); return }
        Task {
            do { try accept(try await request("game", body: ["action": "taunt"])) }
            catch { self.error = error.localizedDescription }
        }
    }

    func eject() {
        guard !busy, snapshot?.eject?.available == true else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try accept(try await request("game", body: ["action": "eject"]))
                try await refresh()
                message = "Ejected! Same disguise, random new spot. No take-backs."
            } catch { self.error = error.localizedDescription }
        }
    }

    func practice() {
        guard let editor else { return }
        editor.editing.room = true; editor.editing.tool = "tag"
        Task { _ = try? await editor.webView?.callAsyncJavaScript("window.characterViewer.visibility([], true); window.characterViewer.beginHunt()", arguments: [:], in: nil, contentWorld: .page) }
        practiceRemaining = 60; practiceScore = 0
        polling?.cancel()
        polling = Task {
            while !Task.isCancelled, let remaining = practiceRemaining, remaining > 0 {
                do { try await Task.sleep(for: .seconds(1)); practiceRemaining = remaining - 1 }
                catch { break }
            }
            message = "Practice finished: \(practiceScore) points."
        }
        message = "Find your disguise from another angle. Finding a clone also finds the original."
    }
}

struct CharacterPlayPanel: View {
    @ObservedObject var model: Character3DModel
    @Environment(\.gameConnection) private var connection
    @ObservedObject var game: CharacterGameModel
    @State private var mode = "basic"
    @State private var preparation = 60
    @State private var hunt = 180
    @State private var autoTaunt = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(connection.map { "Room \($0.code)" } ?? "Solo practice").font(RallyStyle.font(18, .bold))
            if game.snapshot?.phase == "hunting", game.snapshot?.role != "hunter" {
                VStack(alignment: .leading, spacing: 8) {
                    Button { game.eject() } label: {
                        Label(game.snapshot?.eject?.used == true ? "Eject used this round" : "Emergency eject · 1 use", systemImage: "arrow.up.forward.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(PushButtonStyle(destructive: true))
                    .disabled(game.busy || game.snapshot?.eject?.available != true)
                    .accessibilityIdentifier("emergencyEjectButton")
                    Text("Random spot. Same paint, pose and size. You could land in plain sight. No preview or undo; your clones move with you.")
                        .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
            }
            if let snapshot = game.snapshot {
                HStack {
                    Text("\(snapshot.phase.capitalized) · \(snapshot.role.capitalized)")
                    Spacer()
                    Text("\(snapshot.remaining)s").monospacedDigit()
                }.font(RallyStyle.font(13, .semibold))
                ForEach(snapshot.scores) { score in
                    HStack { Text(score.name); Spacer(); Text(score.found ? "Found · \(score.points)" : "\(score.points)") }
                        .font(RallyStyle.font(12))
                }
            }
            Text(game.message).font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            if connection != nil {
                Button { game.publishCurrent() } label: { Label(game.busy ? "Publishing…" : "Publish disguise", systemImage: "square.and.arrow.up") }
                    .disabled(game.busy || model.exporting || model.editing.placementLocked != true || game.snapshot?.phase == "hunting")
                if connection?.isHost == true && (game.snapshot?.phase == "lobby" || game.snapshot?.phase == "finished") {
                    Picker("Game mode", selection: $mode) {
                        Text("Basic").tag("basic"); Text("Infection").tag("infection"); Text("Double").tag("double"); Text("Chicken race").tag("chicken")
                    }
                    Picker("Prepare", selection: $preparation) { Text("30s prep").tag(30); Text("60s prep").tag(60); Text("120s prep").tag(120) }.pickerStyle(.segmented)
                    Picker("Hunt", selection: $hunt) { Text("60s hunt").tag(60); Text("180s hunt").tag(180); Text("300s hunt").tag(300) }.pickerStyle(.segmented)
                    Toggle("Automatic whistle every 30s", isOn: $autoTaunt).font(RallyStyle.font(12))
                    Button("Start round") { game.start(mode: mode, preparation: preparation, hunt: hunt, autoTaunt: autoTaunt) }.disabled(game.busy)
                    Text("Starting shares this room's layout with lobby members. Publish only captures you have permission to share.")
                        .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
                if game.snapshot?.phase == "hunting" {
                    Button("Hunt / tag") { model.editing.room = true; model.editing.tool = "tag" }
                        .disabled(!["hunter", "dual"].contains(game.snapshot?.role ?? ""))
                    Button("Whistle") { game.taunt() }
                }
            } else {
                Button("Start 60-second practice hunt") { game.practice() }
                if let remaining = game.practiceRemaining { Text("\(remaining)s · \(game.practiceScore) points").font(RallyStyle.font(14, .semibold)) }
                Text("Create or join a Rally lobby to play the four multiplayer modes with other people.").font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }
            HStack {
                Button { walk(-1, 0) } label: { Image(systemName: "arrow.left") }.accessibilityLabel("Walk left")
                Button { walk(0, 1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Walk forward")
                Button { walk(0, -1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Walk backward")
                Button { walk(1, 0) } label: { Image(systemName: "arrow.right") }.accessibilityLabel("Walk right")
            }
            if let error = game.error { ErrorNotice(message: error) }
        }
        .font(RallyStyle.font(13, .semibold))
    }

    private func walk(_ horizontal: Int, _ forward: Int) {
        Task { _ = try? await model.webView?.callAsyncJavaScript("window.characterViewer.walk(horizontal, forward)", arguments: ["horizontal": horizontal, "forward": forward], in: nil, contentWorld: .page) }
    }
}
