import MultipeerConnectivity
import SwiftUI

struct HostGameView: View {
    @StateObject private var session: GameSession

    init(name: String, avatar: Int) {
        _session = StateObject(wrappedValue: GameSession(name: name, avatar: avatar, isHost: true))
    }

    var body: some View {
        GameView(session: session)
    }
}

struct JoinGameView: View {
    @StateObject private var session: GameSession
    @Environment(\.dismiss) private var dismiss

    init(name: String, avatar: Int) {
        _session = StateObject(wrappedValue: GameSession(name: name, avatar: avatar, isHost: false))
    }

    var body: some View {
        // A container that stays put, so swapping the list for the game doesn't count as leaving.
        ZStack {
            if session.isConnected {
                GameView(session: session)
            } else {
                hostList
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { session.leave() }
    }

    private var hostList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("Back")
                    Spacer()
                    Brand()
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                Text("Games nearby").font(RallyStyle.font(32, .bold)).accessibilityAddTraits(.isHeader)
                if session.hosts.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking on this Wi-Fi…").font(RallyStyle.font(14, .semibold))
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RallyStyle.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                    Text("The host needs Create room open, on the same Wi-Fi as you.")
                        .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
                ForEach(session.hosts, id: \.self) { host in
                    Button { session.join(host) } label: {
                        HStack(spacing: 14) {
                            AvatarView(index: session.hostAvatars[host] ?? 0, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(host.displayName)'s game").font(RallyStyle.font(17, .bold))
                                Text("Tap to join").font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .padding(16)
                        .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .rallyHover(cornerRadius: 18)
                }
                if let error = session.error { ErrorNotice(message: error) }
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .foregroundStyle(RallyStyle.ink)
    }
}

/// A spot picked for the player's chameleon, plus what the camera saw there for picking colors.
private struct ChameleonSpot {
    let placement: GhostPlacement
    let photo: CGImage?
}

/// One screen for the whole round. The AR view stays alive underneath so the phone keeps
/// knowing where it is; each phase puts its own panel on top.
struct GameView: View {
    @ObservedObject var session: GameSession
    @StateObject private var ar = ARGameController()
    @Environment(\.dismiss) private var dismiss

    @State private var capture: GhostCapture?
    /// Building and painting a 3D ghost; nil means painting the flat cutout.
    @State private var sculptor: GhostSculptor?
    /// Waiting for a tap on the spot to put the player's saved chameleon.
    @State private var placingChameleon = false
    @State private var chameleonSpot: ChameleonSpot?
    @State private var isCapturing = false
    @State private var countdown: Int?
    @State private var useTimer = true
    @State private var captureError: String?
    @State private var confirmingLeave = false
    @State private var serverAddress = ""
    @State private var serverToken = ""

    private var state: GameState { session.state }
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ZStack {
            ARGameViewContainer(controller: ar)
                .ignoresSafeArea()

            if !session.hasMap {
                paperCover {
                    Brand()
                    Text("Getting the house map").font(RallyStyle.font(24, .bold))
                    ProgressView(value: session.mapProgress).tint(RallyStyle.limeEdge).frame(maxWidth: 260)
                    Text("It's a big file, so this can take a minute.")
                        .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                }
            } else if let spot = chameleonSpot, let sculptor {
                Ghost3DView(sculptor: sculptor, photo: spot.photo, placeTitle: "Hide here", onCancel: {
                    chameleonSpot = nil
                    self.sculptor = nil
                })
            } else if let capture, let sculptor {
                Ghost3DView(sculptor: sculptor, photo: capture.photo, waitingImage: capture.person, onUse2D: {
                    sculptor.cancel()
                    self.sculptor = nil
                })
            } else if let capture {
                PaintView(capture: capture, onDone: { image in
                    placeGhost(capture.placement, image: image)
                }, onRetake: {
                    self.capture = nil
                })
            } else {
                phasePanel
            }

            if let countdown {
                Text("\(countdown)")
                    .font(RallyStyle.font(140, .heavy))
                    .foregroundStyle(RallyStyle.lime)
                    .shadow(color: RallyStyle.ink.opacity(0.5), radius: 10)
            }
        }
        .foregroundStyle(RallyStyle.ink)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Couldn't place your ghost", isPresented: Binding(get: { captureError != nil }, set: { if !$0 { captureError = nil } })) {
            Button("OK") {}
        } message: {
            Text(captureError ?? "")
        }
        .alert(session.isHost ? "End this game?" : "Heading out?", isPresented: $confirmingLeave) {
            Button(session.isHost ? "End game" : "Leave game", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.isHost ? "Everyone will be disconnected." : "You can join again from Games nearby.")
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            ar.onTapGhost = { session.tag($0) }
            startARIfReady()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            ar.stop()
            session.leave()
        }
        .onChange(of: session.hasMap) { startARIfReady() }
        .onChange(of: ar.isRelocalized) { session.setReady(ar.isRelocalized) }
        .onChange(of: state) { syncGhosts() }
        .onChange(of: session.ghostImages) { syncGhosts() }
        .onChange(of: session.ghostModels) { syncGhosts() }
        .onChange(of: state.phase) {
            if state.phase != .hiding {
                sculptor?.cancel()
                sculptor = nil
                capture = nil
                chameleonSpot = nil
                placingChameleon = false
                ar.onTapPlace = nil
            }
        }
    }

    private var timeLeft: String {
        String(format: "%d:%02d", state.secondsLeft / 60, state.secondsLeft % 60)
    }

    private func startARIfReady() {
        if session.hasMap {
            ar.start(mapURL: session.mapURL, structureURL: session.structureURL)
        }
    }

    /// Who sees which ghosts: hiders see their own, seekers see everyone's while seeking,
    /// and everyone sees everything at the end.
    private func syncGhosts() {
        let visible: [Ghost]
        switch state.phase {
        case .lobby: visible = []
        case .hiding: visible = state.ghosts.filter { $0.ownerID == session.me.id }
        case .seeking: visible = session.amSeeking ? state.ghosts : state.ghosts.filter { $0.ownerID == session.me.id }
        case .results: visible = state.ghosts
        }
        ar.show(visible, images: session.ghostImages, models: session.ghostModels)
    }

    // MARK: Panels

    @ViewBuilder
    private var phasePanel: some View {
        switch state.phase {
        case .lobby:
            if ar.isRelocalized {
                lobby
            } else {
                cameraCard {
                    Eyebrow(text: "BEFORE YOU PLAY")
                    Text("Find the house").font(RallyStyle.font(23, .bold))
                    Text(ar.trackingMessage).font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                    Text("Walk around slowly and point your phone at the room the host scanned.")
                        .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
            }
        case .hiding:
            if session.myRole == .seeker && state.players.contains(where: { $0.role == .seeker }) {
                paperCover {
                    AvatarView(index: session.me.avatar, size: 125).rotationEffect(.degrees(-7)).accessibilityHidden(true)
                    Text("Eyes closed!").font(RallyStyle.font(40, .heavy))
                    Text("Hiders are hiding.").foregroundStyle(RallyStyle.muted)
                    timerTicket
                }
            } else {
                cameraCard { hidingPanel }
            }
        case .seeking:
            if session.amSeeking {
                cameraCard { seekingPanel }
            } else {
                paperCover {
                    AvatarView(index: session.me.avatar, size: 125).rotationEffect(.degrees(-7)).accessibilityHidden(true)
                    Text("Stay sneaky").font(RallyStyle.font(40, .heavy))
                    Text(session.myGhost?.foundBy == nil ? "Seekers are looking. Your ghost is still hidden."
                                                         : "You've been found!")
                        .foregroundStyle(RallyStyle.muted).multilineTextAlignment(.center)
                    timerTicket
                }
            }
        case .results:
            cameraCard { resultsPanel }
        }
    }

    private var lobby: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Brand()
                VStack(spacing: 14) {
                    Eyebrow(text: "HOSTED BY")
                    Text(state.players.first.map { $0.name } ?? session.me.name)
                        .font(RallyStyle.font(40, .heavy)).tracking(-1)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Rectangle().fill(RallyStyle.limeEdge.opacity(0.7)).frame(height: 1)
                    Label("\(state.players.filter(\.isReady).count) of \(state.players.count) found the house",
                          systemImage: "house")
                        .font(RallyStyle.font(12, .semibold))
                }
                .padding(20).frame(maxWidth: .infinity)
                .background(RallyStyle.lime, in: RoundedRectangle(cornerRadius: 22))

                HStack(spacing: 8) {
                    Text("Players").font(RallyStyle.font(23, .bold)).accessibilityAddTraits(.isHeader)
                    Text("\(state.players.count)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(RallyStyle.muted)
                        .padding(6).background(RallyStyle.line.opacity(0.35), in: Capsule())
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(state.players) { playerTile($0) }
                }
                if session.isHost {
                    hostControls
                } else {
                    Label("Waiting for the host", systemImage: "clock")
                        .font(RallyStyle.font(14, .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(RallyStyle.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                }
                Button(session.isHost ? "End game" : "Leave game") { confirmingLeave = true }
                    .buttonStyle(PushButtonStyle(destructive: true))
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
    }

    private func playerTile(_ player: Player) -> some View {
        let isHostPlayer = player.id == state.players.first?.id
        return VStack(spacing: 8) {
            AvatarView(index: player.avatar, size: 36).accessibilityHidden(true)
            HStack(spacing: 3) {
                Text(player.name).font(RallyStyle.font(14, .bold)).lineLimit(1)
                if player.id == session.me.id { Text("(you)").font(RallyStyle.font(10)).foregroundStyle(RallyStyle.muted) }
            }
            Label(player.isReady ? "Found the house" : "Finding the house",
                  systemImage: isHostPlayer ? "crown" : player.isReady ? "checkmark" : "clock")
                .font(RallyStyle.font(11)).foregroundStyle(player.isReady ? RallyStyle.success : RallyStyle.muted)
            Button { session.toggleRole(of: player.id) } label: {
                Text(player.role == .seeker ? "🔍 Seeker" : "🫥 Hider")
                    .font(RallyStyle.font(12, .bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(player.role == .seeker ? RallyStyle.coral.opacity(0.35) : RallyStyle.cyan.opacity(0.5),
                                in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!session.isHost)
            .accessibilityLabel(session.isHost ? "\(player.name) is a \(player.role.rawValue). Tap to switch." : player.role.rawValue)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 132)
        .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line, lineWidth: 1))
    }

    private var hostControls: some View {
        VStack(spacing: 18) {
            Rectangle().fill(RallyStyle.line).frame(height: 1)
            Stepper("Hide time · \(state.hideSeconds / 60) min", value: Binding(
                get: { state.hideSeconds / 60 }, set: { session.setDurations(hide: $0 * 60, seek: state.seekSeconds) }
            ), in: 1...10)
            .font(RallyStyle.font(14, .semibold))
            Stepper("Seek time · \(state.seekSeconds / 60) min", value: Binding(
                get: { state.seekSeconds / 60 }, set: { session.setDurations(hide: state.hideSeconds, seek: $0 * 60) }
            ), in: 1...15)
            .font(RallyStyle.font(14, .semibold))
            modelServerSettings
            Button { session.startRound() } label: { ActionLabel(text: "Start round") }
                .buttonStyle(PushButtonStyle())
            Text(state.players.contains { $0.role == .seeker }
                 ? "Tap a player's role to switch it."
                 : "Nobody is a seeker yet, so everyone will seek after hiding.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
        }
    }

    private var modelServerSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("3D ghosts").font(RallyStyle.font(14, .semibold))
                Spacer()
                Text(session.modelServer.isConfigured ? "On" : "Off · flat cutouts")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }
            TextField("http://<Mac Wi-Fi IP>:3001", text: $serverAddress)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().rallyField()
                .accessibilityLabel("3D server address")
            SecureField("Server access token", text: $serverToken)
                .textInputAutocapitalization(.never).autocorrectionDisabled().rallyField()
            Button("Save 3D server") {
                session.setModelServer(ModelServer(address: serverAddress, token: serverToken))
            }
            .font(RallyStyle.font(14, .semibold))
            .disabled(ModelServer(address: serverAddress, token: serverToken) == session.modelServer)
            Text("Run `npm run start:3d` in server/ on your Mac (TRIPO_HOST=0.0.0.0 and TRIPO_PROXY_TOKEN set). Each hider's 3D model uses Tripo credits and takes a few minutes, so give hiders 5+ minutes. Leave the address empty for flat cutouts.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            serverAddress = session.modelServer.address
            serverToken = session.modelServer.token
        }
    }

    private var hidingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "HIDE · \(timeLeft)")
            if placingChameleon {
                Text("Tap where to hide").font(RallyStyle.font(23, .bold))
                Text("Tap a wall to stand with your back to it, or the floor to stand there facing you.")
                    .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                Button("Cancel") {
                    placingChameleon = false
                    ar.onTapPlace = nil
                }
                .font(RallyStyle.font(14, .semibold))
            } else {
                if session.myGhost != nil {
                    Text("Hidden ✅").font(RallyStyle.font(23, .bold))
                    Text("You can walk around now. Redo it any time before hiding ends.")
                        .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                } else {
                    Text("Find your spot").font(RallyStyle.font(23, .bold))
                    Text("Place your white chameleon, pick a pose, then paint it to blend in.")
                        .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                }
                if !ar.isRelocalized {
                    Text(ar.trackingMessage).font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
                Button { startPlacingChameleon() } label: {
                    ActionLabel(text: session.myGhost == nil ? "Place my chameleon" : "Hide somewhere else")
                }
                .buttonStyle(PushButtonStyle())
                .disabled(!ar.isRelocalized)
            }
            if session.isHost {
                Button("Start seeking now") { session.endPhase() }
                    .font(RallyStyle.font(14, .semibold))
            }
        }
    }

    private var seekingPanel: some View {
        let found = state.ghosts.filter { $0.foundBy != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "SEEK · \(timeLeft)")
            Text("Found \(found) of \(state.ghosts.count)").font(RallyStyle.font(23, .bold))
            Text(ar.isRelocalized ? "Tap a hider when you spot them." : ar.trackingMessage)
                .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
            if session.isHost {
                Button("End round") { session.endPhase() }
                    .font(RallyStyle.font(14, .semibold))
            }
        }
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "RESULTS")
            Text("Everyone's hiding spot is showing. Look around!")
                .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
            ForEach(state.ghosts) { ghost in
                let owner = state.player(ghost.ownerID)
                HStack(spacing: 10) {
                    AvatarView(index: owner?.avatar ?? 0, size: 32).accessibilityHidden(true)
                    if let finder = state.player(ghost.foundBy)?.name {
                        Text("\(owner?.name ?? "Someone") was found by \(finder)").font(RallyStyle.font(15, .semibold))
                    } else {
                        Text("\(owner?.name ?? "Someone") was never found 🏆").font(RallyStyle.font(15, .bold))
                    }
                }
            }
            if state.ghosts.isEmpty {
                Text("Nobody placed a ghost this round.").font(RallyStyle.font(15, .semibold))
            }
            if session.isHost {
                Button { session.startRound() } label: { ActionLabel(text: "Play again") }
                    .buttonStyle(PushButtonStyle())
                Button { session.endPhase() } label: { ActionLabel(text: "Back to lobby") }
                    .buttonStyle(PushButtonStyle(dark: true))
            } else {
                Label("Waiting for the host", systemImage: "clock").font(RallyStyle.font(14, .semibold))
            }
        }
    }

    private var timerTicket: some View {
        Text(timeLeft)
            .font(.system(size: 47, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 28).padding(.vertical, 12)
            .background(RallyStyle.lime, in: RoundedRectangle(cornerRadius: 22))
    }

    /// Camera stays visible; the panel sits at the bottom as a Rally card, with a leave button up top.
    private func cameraCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            HStack {
                Button { confirmingLeave = true } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).rallyGlass()
                .accessibilityLabel(session.isHost ? "End game" : "Leave game")
                Spacer()
            }
            .padding(.horizontal, 16)
            Spacer()
            VStack(alignment: .leading, spacing: 12, content: content)
                .padding(22).frame(maxWidth: 540, alignment: .leading)
                .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(RallyStyle.line, lineWidth: 1))
                .padding(16)
        }
    }

    private func paperCover<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 20, content: content)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RallyStyle.paper.ignoresSafeArea())
    }

    // MARK: Hiding

    private func takePhoto() {
        Task { @MainActor in
            if useTimer {
                for second in stride(from: 5, through: 1, by: -1) {
                    countdown = second
                    try? await Task.sleep(for: .seconds(1))
                }
                countdown = nil
            }
            guard let frame = ar.currentFrame else { return }
            let floorY = ar.floorHeight(for: frame)
            let walls = ar.walls
            isCapturing = true
            defer { isCapturing = false }
            do {
                let capture = try await Task.detached { try GhostCapture.make(from: frame, floorY: floorY, walls: walls) }.value
                self.capture = capture
                // With a 3D server, build a 3D ghost to paint; otherwise paint the flat cutout.
                if session.modelServer.isConfigured, let png = capture.cutoutPNG() {
                    let sculptor = GhostSculptor()
                    sculptor.onExported = { [weak sculptor] usdz in
                        guard sculptor != nil else { return }
                        placeGhost(capture.placement, image: capture.flatCutoutPNG() ?? Data(), model: usdz)
                    }
                    sculptor.generate(png: png, server: session.modelServer)
                    self.sculptor = sculptor
                }
            } catch {
                captureError = error.localizedDescription
            }
        }
    }

    /// The next tap on the house picks the spot; then the chameleon opens for posing and painting.
    private func startPlacingChameleon() {
        placingChameleon = true
        ar.onTapPlace = { point in
            guard let placement = ar.chameleonPlacement(at: point), let model = ChameleonStore.whiteBody else {
                captureError = "Couldn't find a floor or wall there. Point at it from closer and tap again."
                return
            }
            ar.onTapPlace = nil
            placingChameleon = false
            let photo = ar.currentFrame.flatMap(GhostCapture.uprightPhoto)
            let sculptor = GhostSculptor(modelData: model)
            sculptor.onExported = { usdz in placeGhost(placement, image: Data(), model: usdz) }
            self.sculptor = sculptor
            chameleonSpot = ChameleonSpot(placement: placement, photo: photo)
        }
    }

    private func placeGhost(_ placement: GhostPlacement, image: Data, model: Data? = nil) {
        let id = UUID()
        var modelURL: URL?
        if let model {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-\(id.uuidString).usdz")
            do {
                try model.write(to: url, options: .atomic)
                modelURL = url
            } catch {
                captureError = "Couldn't save your 3D ghost: \(error.localizedDescription)"
                return
            }
        }
        let ghost = Ghost(id: id, ownerID: session.me.id, transform: placement.transform.floats,
                          floorTransform: placement.floorTransform.floats, flushBack: placement.flushBack,
                          hasModel: modelURL != nil, width: placement.width, height: placement.height, foundBy: nil)
        session.placeGhost(ghost, image: image, model: modelURL)
        sculptor = nil
        capture = nil
        chameleonSpot = nil
    }
}
