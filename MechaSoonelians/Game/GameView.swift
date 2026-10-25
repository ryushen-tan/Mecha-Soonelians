import SwiftUI

/// One screen for the whole round. The AR view stays alive underneath so the phone keeps
/// knowing where it is; each phase puts its own panel on top.
struct GameView: View {
    @ObservedObject var session: GameSession
    /// Leaving mid-round: the host closes the round for everyone, anyone else leaves the room.
    var onExit: () -> Void
    @StateObject private var ar = ARGameController()

    @State private var capture: GhostCapture?
    /// Building and painting a 3D ghost; nil means painting the flat cutout.
    @State private var sculptor: GhostSculptor?
    /// Waiting for a tap on the spot to put the player's saved chameleon.
    @State private var placingChameleon = false
    /// Posing, moving and spray-painting the chameleon in AR.
    @State private var spray: SprayPainter?
    @State private var isCapturing = false
    @State private var countdown: Int?
    @State private var useTimer = true
    @State private var captureError: String?
    @State private var confirmingLeave = false
    @State private var confirmingSkip = false
    @State private var chirpSentAt: Date?
    @State private var showingSpots = false
    @State private var announcedChirps: Set<String> = []
    @State private var chirpNotice: Date?
    /// A few seconds of "who's the seeker / go hide" when a phase starts.
    @State private var splash: Splash?

    private struct Splash: Equatable { let title: String; let detail: String }

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
            } else if let spray {
                SprayPaintView(painter: spray, timeLeft: timeLeft, onHide: {
                    hideSprayedChameleon(spray)
                }, onCancel: stopChameleon)
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

            if let splash {
                paperCover {
                    AvatarView(index: session.me.avatar, size: 125).rotationEffect(.degrees(-7)).accessibilityHidden(true)
                    Text(splash.title).font(RallyStyle.font(44, .heavy)).multilineTextAlignment(.center)
                    Text(splash.detail).font(RallyStyle.font(17)).foregroundStyle(RallyStyle.muted).multilineTextAlignment(.center)
                }
                .transition(.opacity)
                .onTapGesture { self.splash = nil }
            }
            if state.phase == .seeking, session.amSeeking, ar.lastChirp != nil {
                chirpCompass
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
            Button(session.isHost ? "End game" : "Leave game", role: .destructive) { onExit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.isHost ? "Everyone goes back to the lobby." : "You'll leave the room.")
        }
        .alert("Start seeking now?", isPresented: $confirmingSkip) {
            Button("Start seeking", role: .destructive) { session.skipPhase() }
            Button("Keep hiding", role: .cancel) {}
        } message: {
            Text("Hiding ends for everyone, even players still placing their ghost.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(session.error ?? "")
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            ar.onTapGhost = { id in
                guard state.phase == .seeking, session.amSeeking else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                session.tag(id)
            }
            session.start()
            startARIfReady()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            spray?.remove()
            ar.stop()
            session.leave()
        }
        .onChange(of: session.hasMap) { startARIfReady() }
        .onChange(of: ar.isRelocalized) { session.setReady(ar.isRelocalized) }
        .onChange(of: state) { syncGhosts(); playChirps() }
        .task(id: state.phase == .seeking && session.myRole == .seeker) {
            // The seeker tells the server which hiders are on screen, once a second.
            guard state.phase == .seeking, session.myRole == .seeker else { return }
            while !Task.isCancelled {
                let seen = ar.ghostsInView(state.ghosts)
                if !seen.isEmpty { session.reportSeen(seen) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: session.ghostImages) { syncGhosts() }
        .onChange(of: session.ghostModels) { syncGhosts() }
        .onChange(of: state.phase) {
            announcePhase()
            showingSpots = false
            if state.phase != .hiding {
                sculptor?.cancel()
                sculptor = nil
                capture = nil
                stopChameleon()
                placingChameleon = false
                ar.onTapPlace = nil
            }
        }
    }

    /// Who won: the seeker if everyone was found, else the hidden hider(s) with the most points.
    private var winnerLine: String {
        let winners = (state.winnerIDs ?? []).compactMap { state.player($0) }
        guard !winners.isEmpty else { return "Round over" }
        if winners.count == 1, winners[0].id == state.seekerID { return "\(winners[0].name) found everyone and wins! 🔍" }
        let names = winners.map(\.name).joined(separator: " & ")
        return winners.count == 1 ? "\(names) wins with \(winners[0].points ?? 0) points! 🏆" : "\(names) tie with \(winners[0].points ?? 0) points! 🏆"
    }

    /// Hider: makes the ghost chirp from its hiding spot. Braver hiders give the seeker a clue.
    private var chirpButton: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let cooling = chirpSentAt.map { Date().timeIntervalSince($0) < 8 } ?? false
            Button {
                chirpSentAt = Date()
                session.chirp()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                ActionLabel(text: cooling ? "Chirped! 🐦" : "Chirp 🐦")
            }
            .buttonStyle(PushButtonStyle())
            .disabled(cooling)
            .accessibilityHint("Your ghost makes a sound the seeker can follow.")
        }
        .frame(maxWidth: 320)
    }

    /// For a second after a chirp, a big arrow shows the seeker which way it came from, turning as
    /// they turn. It gives the direction and a rough distance, not the exact spot.
    private var chirpCompass: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            if let direction = ar.chirpDirection(now: context.date) {
                let degrees = abs(direction.angle) * 180 / .pi
                let side = degrees < 30 ? "ahead" : degrees > 140 ? "behind you" : direction.angle > 0 ? "to your left" : "to your right"
                let range = direction.distance < 2 ? "close" : direction.distance < 5 ? "nearby" : "far"
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 64, weight: .black))
                        .rotationEffect(.radians(-direction.angle))
                        .animation(.easeOut(duration: 0.15), value: direction.angle)
                    Text("Chirp \(side)").font(RallyStyle.font(20, .heavy))
                    Text(range).font(RallyStyle.font(14, .semibold)).foregroundStyle(RallyStyle.muted)
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
                .background(RallyStyle.lime.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
                .foregroundStyle(RallyStyle.ink)
                .padding(.top, 120)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("A hider chirped \(side), \(range)")
            }
        }
    }

    /// Plays every new chirp on the seeker's phone, from where that hider's ghost is.
    private func playChirps() {
        guard state.phase == .seeking, session.myRole == .seeker else { return }
        for chirp in state.chirps ?? [] {
            guard let ghost = state.ghosts.first(where: { $0.id == chirp.ghostID }) else { continue }
            if ar.isRelocalized, chirp.age < 6_000, !announcedChirps.contains(chirp.id) {
                announcedChirps.insert(chirp.id)
                ar.play(chirp, ghost: ghost)
                chirpNotice = Date()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    /// Tells everyone what their job is when a phase starts.
    private func announcePhase() {
        let seekerName = session.seeker?.name ?? "Someone"
        switch state.phase {
        case .hiding:
            splash = session.myRole == .seeker
                ? Splash(title: "You're the seeker!", detail: "Eyes closed. Everyone else is hiding, and you'll get the word when it's time to seek.")
                : Splash(title: "Go hide!", detail: "\(seekerName) is the seeker. Place your ghost before the timer runs out.")
        case .seeking:
            splash = session.myRole == .seeker
                ? Splash(title: "Go seek!", detail: "Tap a hider when you spot them.")
                : nil
        default:
            splash = nil
        }
        guard splash != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { splash = nil }
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
        ar.show(visible, images: session.ghostImages, models: session.ghostModels, burstWhenFound: state.phase == .seeking)
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
                    if let ghost = session.myGhost, ghost.foundBy == nil {
                        let me = state.player(session.me.id)
                        Text(me?.seenNow == true ? "👀 The seeker can see you! +10 a second" : "Points: \(me?.points ?? 0)")
                            .font(RallyStyle.font(17, .bold))
                            .foregroundStyle(me?.seenNow == true ? RallyStyle.coral : RallyStyle.ink)
                        if me?.seenNow == true {
                            Text("Points: \(me?.points ?? 0)").font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                        }
                        chirpButton
                    }
                }
            }
        case .results:
            if showingSpots {
                cameraCard {
                    Eyebrow(text: "EVERYONE'S HIDING SPOTS")
                    Text("Look around: found ghosts are marked green.").font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                    Button { showingSpots = false } label: { ActionLabel(text: "Back to results") }
                        .buttonStyle(PushButtonStyle(dark: true))
                }
            } else {
                resultsPage
            }
        }
    }

    private var lobby: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Brand()
                VStack(spacing: 14) {
                    Eyebrow(text: "THE SEEKER IS")
                    Text(session.seeker?.name ?? "…")
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
                    Label("Hiding starts when everyone has found the house", systemImage: "clock")
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
            Text(player.role == .seeker ? "🔍 Seeker" : "🫥 Hider")
                .font(RallyStyle.font(12, .bold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(player.role == .seeker ? RallyStyle.coral.opacity(0.35) : RallyStyle.cyan.opacity(0.5), in: Capsule())
                .accessibilityLabel("\(player.name) is the \(player.role.rawValue)")
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 132)
        .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line, lineWidth: 1))
    }

    private var hostControls: some View {
        VStack(spacing: 14) {
            Rectangle().fill(RallyStyle.line).frame(height: 1)
            Text("Hiding starts by itself once everyone has found the house. Hiders get \(state.hideSeconds / 60) min to hide; the seeker gets \(state.seekSeconds / 60) min to find them.")
                .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            Button { session.startRound() } label: { ActionLabel(text: "Start hiding now") }
                .buttonStyle(PushButtonStyle())
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
                    Text("Place your scanned 3D self, pick a pose, then paint it to blend in.")
                        .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                }
                if !ar.isRelocalized {
                    Text(ar.trackingMessage).font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                }
                if session.placing {
                    HStack(spacing: 10) { ProgressView(); Text("Hiding your ghost…").font(RallyStyle.font(15, .semibold)) }
                }
                Button { startPlacingChameleon() } label: {
                    ActionLabel(text: session.myGhost == nil ? "Place my chameleon" : "Hide somewhere else")
                }
                .buttonStyle(PushButtonStyle())
                .disabled(!ar.isRelocalized || session.placing)
            }
            if session.isHost {
                Button("Start seeking now") { confirmingSkip = true }
                    .font(RallyStyle.font(14, .semibold))
                    .disabled(session.placing)
            }
        }
    }

    private var seekingPanel: some View {
        let found = state.ghosts.filter { $0.foundBy != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "SEEK · \(timeLeft)")
            if let chirpNotice, Date().timeIntervalSince(chirpNotice) < 4 {
                Label("A hider chirped. Listen and turn toward it!", systemImage: "speaker.wave.3.fill")
                    .font(RallyStyle.font(14, .bold)).foregroundStyle(RallyStyle.coral)
            }
            Text("Found \(found) of \(state.ghosts.count)").font(RallyStyle.font(23, .bold))
            Text(ar.isRelocalized ? "Tap a hider when you spot them." : ar.trackingMessage)
                .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
            // What the phone has, so a missing ghost can be told apart: not downloaded, not in the scene, or not in the house yet.
            let loaded = state.ghosts.filter { session.ghostImages[$0.id] != nil }.count
            Text("Loaded \(loaded) of \(state.ghosts.count) · in the scene \(ar.shownGhostCount) · \(ar.isRelocalized ? "in the house" : "not in the house yet")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(RallyStyle.muted)
            Button("Camera black? Restart it") { ar.restartCamera() }
                .font(RallyStyle.font(13, .semibold))
            if session.isHost {
                Button("End round") { session.skipPhase() }
                    .font(RallyStyle.font(14, .semibold))
            }
        }
    }

    /// The end of the round: who won, everyone's points, and what's next.
    private var resultsPage: some View {
        let hiders = state.players.filter { $0.role == .hider }.sorted { a, b in
            let aHidden = state.ghosts.first { $0.ownerID == a.id }?.foundBy == nil
            let bHidden = state.ghosts.first { $0.ownerID == b.id }?.foundBy == nil
            return aHidden != bHidden ? aHidden : (a.points ?? 0) > (b.points ?? 0)
        }
        let found = state.ghosts.filter { $0.foundBy != nil }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Brand()
                Eyebrow(text: "ROUND OVER")
                Text(winnerLine).font(RallyStyle.font(34, .heavy)).tracking(-1)
                    .fixedSize(horizontal: false, vertical: true)
                if let seeker = session.seeker {
                    resultRow(seeker, detail: "Seeker · found \(found) of \(state.ghosts.count)",
                              won: state.winnerIDs?.contains(seeker.id) == true, points: nil)
                }
                ForEach(hiders) { hider in
                    let ghost = state.ghosts.first { $0.ownerID == hider.id }
                    let detail = ghost == nil ? "Didn't hide" : ghost?.foundBy != nil
                        ? "Found by \(state.player(ghost?.foundBy)?.name ?? "the seeker")" : "Stayed hidden"
                    resultRow(hider, detail: detail, won: state.winnerIDs?.contains(hider.id) == true, points: hider.points ?? 0)
                }
                Text("Hiders earn 10 points a second while the seeker can see them without finding them. If anyone stays hidden, the most points wins; the seeker wins by finding everyone.")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                Button { showingSpots = true } label: { ActionLabel(text: "See everyone's hiding spots") }
                    .buttonStyle(PushButtonStyle(dark: true))
                if session.isHost {
                    Button { session.playAgain() } label: { ActionLabel(text: "Play again") }
                        .buttonStyle(PushButtonStyle())
                    Button("Back to lobby") { onExit() }.font(RallyStyle.font(15, .semibold))
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Waiting for the host to play again", systemImage: "clock").font(RallyStyle.font(14, .semibold))
                    Button("Leave game") { confirmingLeave = true }.font(RallyStyle.font(15, .semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
    }

    private func resultRow(_ player: Player, detail: String, won: Bool, points: Int?) -> some View {
        HStack(spacing: 12) {
            AvatarView(index: player.avatar, size: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.name + (player.id == session.me.id ? " (you)" : "") + (won ? " 🏆" : ""))
                    .font(RallyStyle.font(17, .bold))
                Text(detail).font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
            }
            Spacer()
            if let points { Text("\(points) pts").font(.system(size: 17, weight: .bold, design: .monospaced)) }
        }
        .padding(14)
        .background(won ? RallyStyle.lime : RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line, lineWidth: 1))
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
                // Build a 3D ghost to paint; without a cutout, paint the flat capture.
                if let png = capture.cutoutPNG() {
                    let sculptor = GhostSculptor()
                    sculptor.onExported = { [weak sculptor] usdz in
                        guard sculptor != nil else { return }
                        placeGhost(capture.placement, image: capture.flatCutoutPNG() ?? Data(), model: usdz)
                    }
                    sculptor.generate(png: png)
                    self.sculptor = sculptor
                }
            } catch {
                captureError = error.localizedDescription
            }
        }
    }

    /// The next tap on the house picks the spot; then the white chameleon stands there in AR to
    /// pose, move and spray paint.
    private func startPlacingChameleon() {
        placingChameleon = true
        ar.onTapPlace = { point in
            guard let placement = ar.chameleonPlacement(at: point) else {
                captureError = "Couldn't find a floor or wall there. Point at it from closer and tap again."
                return
            }
            ar.onTapPlace = nil
            placingChameleon = false
            stopChameleon()
            guard let painter = SprayPainter(ar: ar, placement: placement) else {
                captureError = "Your character doesn't fit here, or its saved model is unavailable. Try a clearer surface; reopen the app if this keeps happening."
                return
            }
            painter.load()
            spray = painter
        }
    }

    private func hideSprayedChameleon(_ painter: SprayPainter) {
        guard let paint = painter.paintJPEG() else {
            captureError = "Couldn't save your paint job. Try Hide here again."
            return
        }
        let body: Data
        do { body = try painter.exportBody() }
        catch { captureError = "Couldn't save your 3D character. Try Hide here again."; return }
        let placement = painter.placement, pose = painter.poseID
        stopChameleon()
        placeGhost(placement, image: paint, model: body, pose: pose)
    }

    private func stopChameleon() {
        spray?.remove()
        spray = nil
    }

    /// Hides the player here. A `pose` means a spray-painted chameleon, and `image` is its paint.
    private func placeGhost(_ placement: GhostPlacement, image: Data, model: Data? = nil, pose: String? = nil) {
        let id = UUID()
        var modelURL: URL?
        if let model {
            let extensionName = pose == nil ? "usdz" : "body"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-\(id.uuidString).\(extensionName)")
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
                          hasModel: modelURL != nil, paintedBody: pose != nil, pose: pose, width: placement.width,
                          height: placement.height, foundBy: nil, modelFormat: modelURL?.pathExtension)
        session.placeGhost(ghost, image: image, model: modelURL)
        sculptor = nil
        capture = nil
    }
}
