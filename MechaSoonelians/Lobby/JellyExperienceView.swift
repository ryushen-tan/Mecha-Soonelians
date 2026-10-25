import SpriteKit
import SwiftUI

struct JellyExperienceView: View {
    @EnvironmentObject private var store: LobbyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @Binding var invitationCode: String?
    @StateObject private var sceneState = JellySceneState()
    @StateObject private var audio = JellyAudio()
    @State private var entry = JellyEntry.landing

    private var reduced: Bool { reduceMotion || ProcessInfo.processInfo.arguments.contains("-jelly-still") }
    private var hasCard: Bool { entry != .landing || store.membership != nil }

    var body: some View {
        ZStack {
            JellyStage(state: sceneState, play: { entry = .code; audio.key(.click) })
                .blur(radius: hasCard ? 10 : 0)
                .allowsHitTesting(!hasCard)
                .accessibilityHidden(hasCard)
                .ignoresSafeArea()
            if hasCard {
                JellyStyle.background.opacity(0.55).ignoresSafeArea()
                GeometryReader { geometry in
                    ScrollView {
                        Group {
                            if let room = store.room {
                                LobbyView(room: room)
                            } else if store.membership != nil {
                                reconnectCard
                            } else {
                                HomeView(entry: $entry, invitationCode: $invitationCode)
                            }
                        }
                        .padding(20).frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            } else {
                hud
            }
        }
        .foregroundStyle(JellyStyle.ink).tint(JellyStyle.blue)
        .animation(reduced ? nil : .easeOut(duration: 0.25), value: hasCard)
        .environmentObject(audio)
        .onChange(of: sceneState.filled) { _, filled in if filled { audio.startMusic() } }
        .onAppear(perform: configureScene)
        .onChange(of: phase, initial: true) { _, _ in configureScene() }
        .onChange(of: reduced) { _, _ in configureScene() }
        .onChange(of: store.membership?.token) { previous, current in
            if previous != nil && current == nil { entry = .code }
        }
        .onChange(of: invitationCode, initial: true) { _, code in
            if code != nil { entry = .code }
        }
        .onDisappear { audio.setActive(false); sceneState.scene.configure(reducedMotion: reduced, suspended: true) }
    }

    private func configureScene() {
        let active = phase == .active
        sceneState.scene.configure(reducedMotion: reduced, suspended: !active)
        audio.setActive(active)
    }

    private var hud: some View {
        VStack {
            HStack {
                JellyCount(state: sceneState)
                Spacer()
                Button { audio.toggleMute() } label: {
                    Label(audio.muted ? "Sound off" : "Sound on", systemImage: audio.muted ? "speaker.slash" : "music.note")
                }
                .accessibilityIdentifier("soundButton")
                .accessibilityValue(audio.muted ? "Off" : "On")
            }
            Spacer()
            HStack {
                JellyTiltButton(state: sceneState, reduced: reduced)
                Spacer()
                Button {
                    audio.restartPour(); sceneState.scene.refill()
                    if reduced { audio.startMusic() }
                } label: { Label("Pour again", systemImage: "arrow.clockwise") }
                .accessibilityIdentifier("refillButton")
            }
        }
        .buttonStyle(JellyButtonStyle(kind: .ghost))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var reconnectCard: some View {
        JellyCard {
            ProgressView()
            Text(store.reconnecting ? "Reconnecting…" : "Finding your room…").font(JellyStyle.display(26))
            Text("You’ll return to your seat when the server responds.").font(JellyStyle.body()).foregroundStyle(JellyStyle.muted)
            Button("Leave room") { Task { await store.leave() } }
                .buttonStyle(JellyButtonStyle(kind: .danger, fullWidth: true)).disabled(store.busy)
        }
    }
}

private struct JellyStage: View {
    let state: JellySceneState
    @ObservedObject private var position: JellyPlayPosition
    let play: () -> Void

    init(state: JellySceneState, play: @escaping () -> Void) {
        self.state = state; position = state.playPosition; self.play = play
    }
    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                SpriteView(scene: state.scene, preferredFramesPerSecond: 60)
                    .accessibilityHidden(true)
                if position.frame != .zero {
                    Button(action: play) { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .frame(width: position.frame.width, height: max(44, position.frame.height))
                        .position(x: position.frame.midX, y: position.frame.midY)
                        .accessibilityLabel("Play").accessibilityIdentifier("playButton")
                        .hoverEffect(.highlight)
                }
            }
        }
    }
}

private struct JellyCount: View {
    @ObservedObject var state: JellySceneState
    var body: some View {
        Text("\(state.count)").font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted).accessibilityHidden(true)
    }
}

private struct JellyTiltButton: View {
    @ObservedObject var state: JellySceneState
    let reduced: Bool
    var body: some View {
        if state.scene.supportsTilt && !reduced {
            Button { state.scene.toggleTilt() } label: {
                Label(state.tiltEnabled ? "Tilt on" : "Enable tilt", systemImage: "iphone.gen3.radiowaves.left.and.right")
            }
            .accessibilityValue(state.tiltEnabled ? "On" : "Off")
        } else if !reduced {
            Text("DRAG TO PLAY").font(JellyStyle.body(11)).tracking(0.7).foregroundStyle(JellyStyle.muted)
                .padding(12).background(JellyStyle.paper.opacity(0.85), in: Capsule())
                .allowsHitTesting(false)
        }
    }
}
