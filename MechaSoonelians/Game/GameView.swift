import SwiftUI

// Hallmark · playful · blue Jelly palette · design-system: design.md.
// Round roster, centered waiting state, and results list. Critique: P5 H4 E4 S5 R4 V4.

/// One screen for the whole round. The AR view stays alive underneath so the phone keeps
/// knowing where it is; each phase puts its own panel on top.
struct GameView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var session: GameSession
    /// Leaving mid-round: the host closes the round for everyone, anyone else leaves the room.
    var onExit: () -> Void
    @StateObject private var ar = ARGameController()
    @StateObject private var audio = JellyAudio()

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
    @State private var announcedChirps: Set<String> = []
    @State private var chirpNotice: Date?
    @State private var foundFeedback: UUID?
    @State private var lastShotAt = Date.distantPast
    /// A few seconds of "who's the seeker / go hide" when a phase starts.
    @State private var splash: Splash?

    private struct Splash: Equatable { let title: String; let detail: String }

    private var state: GameState { session.state }
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 160), spacing: 12)]
    }

    #if DEBUG
    var previewOnly = false
    var previewFound = false
    /// Renders production panels for visual QA without the camera, timers, or server side effects.
    var previewPanel: some View {
        ZStack {
            if state.phase == .lobby { lobby } else { phasePanel }
            if state.phase == .seeking && session.amSeeking { seekingAim(found: previewFound) }
        }
        .environmentObject(audio)
        .font(JellyStyle.body(15))
        .foregroundStyle(JellyStyle.ink)
        .tint(JellyStyle.blue)
    }
    #endif

    @ViewBuilder var body: some View {
        #if DEBUG
        if previewOnly { previewPanel } else { liveBody }
        #else
        liveBody
        #endif
    }

    private var liveBody: some View {
        ZStack {
            ARGameViewContainer(controller: ar)
                .ignoresSafeArea()

            if !session.hasMap {
                paperCover {
                    JellyWordmark()
                    Text("Getting the house map").font(JellyStyle.display(24))
                    ProgressView(value: session.mapProgress).tint(JellyStyle.blue).frame(maxWidth: 260)
                    Text("It's a big file, so this can take a minute.")
                        .font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
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
            } else if foundFeedback != nil && state.phase == .results {
                // Keep the last reveal visible briefly before presenting the results.
                Color.clear
            } else {
                phasePanel
            }

            if (state.phase == .seeking && session.amSeeking) || foundFeedback != nil {
                seekingAim(found: foundFeedback != nil)
            }

            if let splash {
                paperCover {
                    PlayerAvatar(name: session.me.name, color: session.me.avatar, size: 112).accessibilityHidden(true)
                    Text(splash.title).font(JellyStyle.display(44)).multilineTextAlignment(.center)
                    Text(splash.detail).font(JellyStyle.body(17)).foregroundStyle(JellyStyle.muted).multilineTextAlignment(.center)
                }
                .transition(.opacity)
                .onTapGesture { self.splash = nil }
            }
            if state.phase == .seeking, session.amSeeking, ar.lastChirp != nil {
                chirpCompass
            }
            if let countdown {
                Text("\(countdown)")
                    .font(JellyStyle.display(140))
                    .foregroundStyle(JellyStyle.blue)
                    .shadow(color: JellyStyle.ink.opacity(0.5), radius: 10)
            }
        }
        .environmentObject(audio)
        .font(JellyStyle.body(15))
        .tint(JellyStyle.blue)
        .foregroundStyle(JellyStyle.ink)
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
        .onChange(of: state) { previous, next in
            if previous.phase == .seeking,
               next.ghosts.contains(where: { ghost in
                   ghost.foundBy == session.me.id && previous.ghosts.contains { $0.id == ghost.id && $0.foundBy == nil }
               }) {
                foundFeedback = UUID()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            syncGhosts()
            playChirps()
        }
        .task(id: foundFeedback) {
            guard foundFeedback != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            foundFeedback = nil
        }
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
        if winners.count == 1, winners[0].id == state.seekerID { return "\(winners[0].name) found everyone and wins!" }
        let names = winners.map(\.name).joined(separator: " & ")
        return winners.count == 1 ? "\(names) wins with \(winners[0].points ?? 0) points!" : "\(names) tie with \(winners[0].points ?? 0) points!"
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
                Label(cooling ? "Chirped!" : "Chirp", systemImage: "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(JellyButtonStyle(fullWidth: true))
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
                    Text("Chirp \(side)").font(JellyStyle.body(20))
                    Text(range).font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
                .background(JellyStyle.blue.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
                .foregroundStyle(JellyStyle.ink)
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
                ? Splash(title: "Go seek!", detail: "Aim at a hidden figure and press Shoot.")
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
                    JellyEyebrow(text: "BEFORE YOU PLAY")
                    Text("Find the house").font(JellyStyle.display(23))
                    Text(ar.trackingMessage).font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
                    Text("Walk around slowly and point your phone at the room the host scanned.")
                        .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                }
            }
        case .hiding:
            if session.myRole == .seeker && state.players.contains(where: { $0.role == .seeker }) {
                paperCover {
                    PlayerAvatar(name: session.me.name, color: session.me.avatar, size: 112).accessibilityHidden(true)
                    Text("Eyes closed!").font(JellyStyle.display(40))
                    Text("Hiders are hiding.").foregroundStyle(JellyStyle.muted)
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
                    PlayerAvatar(name: session.me.name, color: session.me.avatar, size: 112).accessibilityHidden(true)
                    Text("Stay sneaky").font(JellyStyle.display(40))
                    Text(session.myGhost?.foundBy == nil ? "Seekers are looking. Your ghost is still hidden."
                                                         : "You've been found!")
                        .foregroundStyle(JellyStyle.muted).multilineTextAlignment(.center)
                    timerTicket
                    if let ghost = session.myGhost, ghost.foundBy == nil {
                        let me = state.player(session.me.id)
                        Text(me?.seenNow == true ? "The seeker can see you! +10 a second" : "Points: \(me?.points ?? 0)")
                            .font(JellyStyle.body(17))
                            .foregroundStyle(me?.seenNow == true ? JellyStyle.blue : JellyStyle.ink)
                        if me?.seenNow == true {
                            Text("Points: \(me?.points ?? 0)").font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
                        }
                        chirpButton
                    }
                }
            }
        case .results:
            resultsPage
        }
    }

    private var lobby: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JellyWordmark()
                VStack(spacing: 14) {
                    JellyEyebrow(text: "THE SEEKER IS").foregroundStyle(.white.opacity(0.85))
                    Text(session.seeker?.name ?? "…")
                        .font(JellyStyle.display(40)).tracking(-1)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Rectangle().fill(.white.opacity(0.35)).frame(height: 1)
                    Label("\(state.players.filter(\.isReady).count) of \(state.players.count) found the house",
                          systemImage: "house")
                        .font(JellyStyle.body(12))
                }
                .padding(20).frame(maxWidth: .infinity)
                .foregroundStyle(.white)
                .background(JellyStyle.blue, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(JellyStyle.ink, lineWidth: 2))

                HStack(spacing: 8) {
                    Text("Players").font(JellyStyle.display(23)).accessibilityAddTraits(.isHeader)
                    Text("\(state.players.count)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(JellyStyle.muted)
                        .padding(6).background(JellyStyle.field, in: Capsule())
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(state.players) { playerTile($0) }
                }
                if session.isHost {
                    hostControls
                } else {
                    Label("Hiding starts when everyone has found the house", systemImage: "clock")
                        .font(JellyStyle.body(14)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(JellyStyle.field, in: RoundedRectangle(cornerRadius: 14))
                }
                Button(session.isHost ? "End game" : "Leave game") { confirmingLeave = true }
                    .buttonStyle(JellyButtonStyle(kind: .danger, fullWidth: true))
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(JellyStyle.background.ignoresSafeArea())
    }

    private func playerTile(_ player: Player) -> some View {
        let isHostPlayer = player.id == state.players.first?.id
        return VStack(spacing: 8) {
            PlayerAvatar(name: player.name, color: player.avatar, size: 48).accessibilityHidden(true)
            HStack(spacing: 3) {
                Text(player.name).font(JellyStyle.body(14)).fixedSize(horizontal: false, vertical: true)
                if player.id == session.me.id { Text("(you)").font(JellyStyle.body(10)).foregroundStyle(JellyStyle.muted) }
            }
            Label(player.isReady ? "Found the house" : "Finding the house",
                  systemImage: isHostPlayer ? "crown" : player.isReady ? "checkmark" : "clock")
                .font(JellyStyle.body(11)).foregroundStyle(player.isReady ? JellyStyle.success : JellyStyle.muted)
            Label(player.role == .seeker ? "Seeker" : "Hider", systemImage: player.role == .seeker ? "magnifyingglass" : "person.fill")
                .font(JellyStyle.body(12))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(player.role == .seeker ? JellyStyle.blue : JellyStyle.ink)
                .background(player.role == .seeker ? JellyStyle.blue.opacity(0.1) : JellyStyle.field, in: Capsule())
                .accessibilityLabel("\(player.name) is the \(player.role.rawValue)")
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 132)
        .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(JellyStyle.ink, lineWidth: 2))
    }

    private var hostControls: some View {
        VStack(spacing: 14) {
            Rectangle().fill(JellyStyle.ink).frame(height: 1)
            Text("Hiding starts by itself once everyone has found the house. Hiders get \(state.hideSeconds / 60) min to hide; the seeker gets \(state.seekSeconds / 60) min to find them.")
                .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
            Button { session.startRound() } label: { ActionLabel(text: "Start hiding now") }
                .buttonStyle(JellyButtonStyle(fullWidth: true))
        }
    }

    private var hidingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            JellyEyebrow(text: "HIDE · \(timeLeft)")
            if placingChameleon {
                Text("Tap where to hide").font(JellyStyle.display(23))
                Text("Tap a wall to stand with your back to it, or the floor to stand there facing you.")
                    .font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
                Button("Cancel") {
                    placingChameleon = false
                    ar.onTapPlace = nil
                }
                .font(JellyStyle.body(14))
            } else {
                if session.myGhost != nil {
                    Text("Hidden").font(JellyStyle.display(23))
                    Text("You can walk around now. Redo it any time before hiding ends.")
                        .font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
                } else {
                    Text("Find your spot").font(JellyStyle.display(23))
                    Text("Place your scanned 3D self, pick a pose, then paint it to blend in.")
                        .font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
                }
                if !ar.isRelocalized {
                    Text(ar.trackingMessage).font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                }
                if session.placing {
                    HStack(spacing: 10) { ProgressView(); Text("Hiding your ghost…").font(JellyStyle.body(15)) }
                }
                Button { startPlacingChameleon() } label: {
                    ActionLabel(text: session.myGhost == nil ? "Place my chameleon" : "Hide somewhere else")
                }
                .buttonStyle(JellyButtonStyle(kind: session.myGhost == nil ? .primary : .ghost, fullWidth: true))
                .disabled(!ar.isRelocalized || session.placing)
            }
            if session.isHost {
                if session.myGhost != nil && !placingChameleon {
                    Button { confirmingSkip = true } label: {
                        ActionLabel(text: "Ready to be found")
                    }
                    .buttonStyle(JellyButtonStyle(fullWidth: true))
                    .disabled(session.placing)
                } else {
                    Button("Start seeking now") { confirmingSkip = true }
                        .font(JellyStyle.body(14))
                        .disabled(session.placing)
                }
            }
        }
    }

    private func seekingAim(found: Bool) -> some View {
        ZStack {
            Circle().stroke(JellyStyle.paper, lineWidth: 6).frame(width: 44, height: 44)
            Circle().stroke(JellyStyle.success, lineWidth: 3).frame(width: 44, height: 44)
            Image(systemName: "plus").font(.system(size: 24, weight: .bold))
                .foregroundStyle(JellyStyle.paper).shadow(color: JellyStyle.ink, radius: 2)
            if found {
                Text("Found Ya!").font(JellyStyle.display(26))
                    .foregroundStyle(JellyStyle.ink)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(JellyStyle.paper, in: Capsule())
                    .overlay(Capsule().strokeBorder(JellyStyle.success, lineWidth: 3))
                    .offset(y: -66)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(found ? "Found Ya!" : "Aim at a hidden figure")
    }

    private func shoot() {
        guard state.phase == .seeking, session.amSeeking, ar.isRelocalized,
              Date().timeIntervalSince(lastShotAt) >= 0.25 else { return }
        lastShotAt = Date()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let id = ar.shoot() { session.tag(id) }
    }

    private var seekingPanel: some View {
        let found = state.ghosts.filter { $0.foundBy != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            JellyEyebrow(text: "SEEK · \(timeLeft)")
            if let chirpNotice, Date().timeIntervalSince(chirpNotice) < 4 {
                Label("A hider chirped. Listen and turn toward it!", systemImage: "speaker.wave.3.fill")
                    .font(JellyStyle.body(14)).foregroundStyle(JellyStyle.blue)
            }
            Text("Found \(found) of \(state.ghosts.count)").font(JellyStyle.display(23))
            Text(ar.isRelocalized ? "Aim + at a hidden figure and press Shoot." : ar.trackingMessage)
                .font(JellyStyle.body(14)).foregroundStyle(JellyStyle.muted)
            Button(action: shoot) {
                HStack(spacing: 10) {
                    Circle().fill(JellyStyle.success).frame(width: 18, height: 18)
                    Text("Shoot")
                    Spacer()
                    Image(systemName: "scope")
                }
            }
            .buttonStyle(JellyButtonStyle(fullWidth: true))
            .disabled(!ar.isRelocalized)
            .accessibilityHint("Fires green paint at the plus. Hitting a hider reveals their original appearance.")
            Button("Camera black? Restart it") { ar.restartCamera() }
                .font(JellyStyle.body(13))
            if session.isHost {
                Button("End round") { session.skipPhase() }
                    .font(JellyStyle.body(14))
            }
        }
    }

    /// Running totals for this room, with this round's gain shown separately.
    private var resultsPage: some View {
        let found = state.ghosts.filter { $0.foundBy != nil }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                JellyWordmark()
                JellyEyebrow(text: "ROUND \(state.roundNumber ?? 1) COMPLETE")
                Text("Leaderboard").font(JellyStyle.display(34)).tracking(-1)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("Total points · blue shows this round's gain")
                    .font(JellyStyle.body(13)).foregroundStyle(JellyStyle.muted)
                ForEach(state.leaderboard) { player in
                    let ghost = state.ghosts.first { $0.ownerID == player.id }
                    let detail = player.role == .seeker ? "Seeker · found \(found) of \(state.ghosts.count)"
                        : ghost == nil ? "Didn't hide" : ghost?.foundBy != nil ? "Found" : "Stayed hidden"
                    resultRow(player, rank: state.rank(of: player), detail: detail)
                }
                Text(winnerLine).font(JellyStyle.body(14))
                Text("Play again to keep adding to these totals. Returning to the lobby starts a fresh scoreboard.")
                    .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                if session.isHost {
                    Button { session.playAgain() } label: { ActionLabel(text: "Play again") }
                        .buttonStyle(JellyButtonStyle(fullWidth: true))
                    Button("Back to lobby") { onExit() }.font(JellyStyle.body(15))
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Waiting for the host to play again", systemImage: "clock").font(JellyStyle.body(14))
                    Button("Leave game") { confirmingLeave = true }.font(JellyStyle.body(15))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(JellyStyle.background.ignoresSafeArea())
    }

    private func resultRow(_ player: Player, rank: Int, detail: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            HStack(spacing: 10) {
                Text("\(rank)").font(JellyStyle.body(18)).frame(minWidth: 18)
                PlayerAvatar(name: player.name, color: player.avatar, size: 36).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name + (player.id == session.me.id ? " (you)" : ""))
                        .font(JellyStyle.body(16)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let scoreLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: 12))
                : AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
            scoreLayout {
                Text("\(player.totalPoints ?? player.points ?? 0)").font(JellyStyle.body(20)).monospacedDigit()
                Text("+\(player.points ?? 0) pts").font(JellyStyle.body(13)).monospacedDigit()
                    .foregroundStyle(JellyStyle.blue)
            }
            .fixedSize()
        }
        .padding(12)
        .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(JellyStyle.ink, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(rank), \(player.name)\(player.id == session.me.id ? ", you" : "")")
        .accessibilityValue("\(player.totalPoints ?? player.points ?? 0) total points, plus \(player.points ?? 0) this round. \(detail)")
    }

    private var timerTicket: some View {
        Text(timeLeft)
            .font(JellyStyle.display(52)).monospacedDigit()
            .padding(.horizontal, 28).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(JellyStyle.blue, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(JellyStyle.ink, lineWidth: 2))
    }

    /// Camera stays visible; a Jelly panel holds the round controls with a leave button up top.
    private func cameraCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            HStack {
                Button { confirmingLeave = true } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 44, height: 44)
                }
                .buttonStyle(JellyButtonStyle(kind: .ghost))
                .accessibilityLabel(session.isHost ? "End game" : "Leave game")
                Spacer()
            }
            .padding(.horizontal, 16)
            Spacer()
            VStack(alignment: .leading, spacing: 12, content: content)
                .padding(22).frame(maxWidth: 540, alignment: .leading)
                .background(JellyStyle.paper, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(JellyStyle.ink, lineWidth: 2))
                .padding(16)
        }
    }

    private func paperCover<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20, content: content)
                    .font(JellyStyle.body(16))
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: 540)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .background(JellyStyle.background.ignoresSafeArea())
        }
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
        guard ChameleonBody.personal != nil else {
            captureError = "Your character isn't ready for placement. Return to the lobby and finish character setup. A generated mesh needs a humanoid rig and prepared poses before it can be placed."
            return
        }
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
