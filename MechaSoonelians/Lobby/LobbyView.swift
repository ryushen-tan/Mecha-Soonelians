import SwiftUI
import UIKit

struct LobbyView: View {
    @EnvironmentObject private var store: LobbyStore
    @EnvironmentObject private var audio: JellyAudio
    let room: Room
    @State private var confirmingLeave = false
    @State private var copied = false
    @State private var showsStudio = false
    @State private var removing: LobbyPlayer?

    var body: some View {
        JellyCard {
            HStack(alignment: .top) {
                Text(room.started ? "Game on!" : store.isHost ? "Your room code" : "You’re in, \(store.me?.name ?? "friend")!")
                    .font(JellyStyle.display(28)).accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Menu {
                    Button { showsStudio = true } label: { Label("Studio", systemImage: "viewfinder") }
                        .accessibilityIdentifier("lobbyStudioButton")
                    ShareLink(item: "Join my room: \(room.displayCode)\nrally://join/\(room.code)") {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                    }
                    if store.isHost && !room.started {
                        Button { Task { await store.setLocked() } } label: {
                            Label(room.locked ? "Unlock room" : "Lock room", systemImage: room.locked ? "lock.open" : "lock")
                        }.disabled(store.busy || store.reconnecting).accessibilityIdentifier("roomLockToggle")
                    }
                    Button { audio.toggleMute() } label: {
                        Label(audio.muted ? "Sound on" : "Sound off", systemImage: audio.muted ? "speaker.wave.2" : "speaker.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        .background(JellyStyle.field, in: Circle())
                }
                .accessibilityLabel("Room options").accessibilityIdentifier("roomOptionsButton")
            }
            if !store.isHost && !room.started {
                Label("Waiting for the host to start…", systemImage: "clock")
                    .font(JellyStyle.body()).foregroundStyle(JellyStyle.success)
            }
            if store.isHost || room.started {
                Text(room.code).font(JellyStyle.display(52)).tracking(5).lineLimit(1).minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Room code " + room.code.map(String.init).joined(separator: " "))
                    .accessibilityIdentifier("lobbyRoomCode")
            } else {
                Text("Room \(room.displayCode)").font(JellyStyle.body()).foregroundStyle(JellyStyle.muted)
                    .accessibilityIdentifier("lobbyRoomCode")
            }
            HStack {
                Text("\(room.members.count) \(room.members.count == 1 ? "player" : "players")")
                if room.locked { Label("Locked", systemImage: "lock.fill") }
                Spacer()
                Button {
                    UIPasteboard.general.string = room.code; copied = true; audio.key(.click)
                } label: { Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "square.on.square") }
                    .buttonStyle(.plain).frame(minHeight: 44).accessibilityIdentifier("copyCodeButton")
            }
            .font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(room.members) { player in playerRow(player) }
                }
            }
            .frame(height: min(CGFloat(room.members.count) * 60, 270))
            .accessibilityIdentifier("playerList")
            if store.reconnecting {
                Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                    .font(JellyStyle.body(13)).foregroundStyle(JellyStyle.muted)
                    .accessibilityIdentifier("reconnectingNotice")
            }
            if let status = store.startingStatus {
                Label(status, systemImage: "icloud.and.arrow.up").font(JellyStyle.body(13)).foregroundStyle(JellyStyle.muted)
            }
            if let error = store.error { JellyNotice(message: error) }
            if store.isHost && !room.started {
                Stepper("Hide time · \(store.hideMinutes) min", value: $store.hideMinutes, in: 1...10)
                    .font(JellyStyle.body(14))
                Stepper("Seek time · \(store.seekMinutes) min", value: $store.seekMinutes, in: 1...15)
                    .font(JellyStyle.body(14))
            }
            if room.started {
                Button { showsStudio = true } label: { Label("Open Studio", systemImage: "viewfinder") }
                    .buttonStyle(JellyButtonStyle(fullWidth: true)).accessibilityIdentifier("openStudioButton")
                if store.isHost {
                    Button("Back to lobby") { Task { await store.reset() } }
                        .buttonStyle(JellyButtonStyle(kind: .ghost, fullWidth: true))
                        .disabled(store.busy || store.reconnecting)
                }
            } else if store.isHost {
                Text(room.members.count < 2 ? "Share your code to invite a friend." : room.canStart ? "Everyone is ready." : "\(room.readyCount) of \(room.members.count) ready.")
                    .font(JellyStyle.body(13)).foregroundStyle(JellyStyle.muted)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { roomActions }
                VStack(spacing: 10) { roomActions }
            }
        }
        .fullScreenCover(isPresented: $showsStudio) {
            NavigationStack {
                StudioView().toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { showsStudio = false } }
                }
            }.buttonStyle(HoverButtonStyle()).tint(RallyStyle.ink)
        }
        .onChange(of: showsStudio) { _, visible in audio.setActive(!visible) }
        .alert(store.isHost ? "End this room?" : "Leave this room?", isPresented: $confirmingLeave) {
            Button(store.isHost ? "End room" : "Leave room", role: .destructive) { Task { await store.leave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.isHost ? "Everyone will return to the join screen." : "You can join again with the same room code.")
        }
        .alert("Remove \(removing?.name ?? "player")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { Task { await store.remove(removing) } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lobbyScreen")
    }

    @ViewBuilder private var roomActions: some View {
        Button(store.isHost ? "End room" : "Leave room") { confirmingLeave = true }
            .buttonStyle(JellyButtonStyle(kind: .ghost, fullWidth: true))
            .disabled(store.busy).accessibilityIdentifier("leaveRoomButton")
        if !room.started {
            if store.isHost {
                Button { Task { await store.start() } } label: {
                    HStack { Text("Start game"); if store.busy { ProgressView().tint(.white) } }
                }
                .buttonStyle(JellyButtonStyle(fullWidth: true))
                .disabled(!room.canStart || store.busy || store.reconnecting)
                .accessibilityIdentifier("startSessionButton")
            } else {
                Button { Task { await store.setReady() } } label: {
                    Label(store.me?.ready == true ? "Ready" : "I’m ready", systemImage: "checkmark")
                }
                .buttonStyle(JellyButtonStyle(kind: store.me?.ready == true ? .dark : .primary, fullWidth: true))
                .disabled(store.busy || store.reconnecting).accessibilityIdentifier("readyButton")
                .accessibilityHint(store.me?.ready == true ? "Tap to undo ready" : "Tell the host you are ready")
            }
        }
    }

    private func playerRow(_ player: LobbyPlayer) -> some View {
        HStack(spacing: 10) {
            PlayerAvatar(name: player.name, color: player.avatar, size: 40).accessibilityHidden(true)
            Text(player.name).font(JellyStyle.body(16)).lineLimit(1)
            if player.id == store.me?.id { Text("you").font(JellyStyle.body(11)).foregroundStyle(JellyStyle.muted) }
            Spacer(minLength: 4)
            if player.host {
                Text("Host").font(JellyStyle.body(11)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(JellyStyle.blue, in: Capsule())
            } else {
                Image(systemName: player.ready ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(player.ready ? JellyStyle.success : JellyStyle.muted)
                    .accessibilityLabel(player.ready ? "Ready" : "Getting ready")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 52)
        .background(JellyStyle.field, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if store.isHost && !player.host {
                Button("Remove \(player.name)", role: .destructive) { removing = player }.disabled(store.busy)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
