import SwiftUI
import UIKit

struct LobbyView: View {
    @EnvironmentObject private var store: LobbyStore
    let room: Room
    @State private var confirmingLeave = false
    @State private var copied = false
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Brand()
                if store.reconnecting {
                    Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                        .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                        .accessibilityIdentifier("reconnectingNotice")
                }
                if room.started {
                    startedContent
                } else {
                    roomTicket
                    HStack(spacing: 8) {
                        Text("Players").font(RallyStyle.font(23, .bold)).accessibilityAddTraits(.isHeader)
                        Text("\(room.members.count)/\(room.capacity)")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(RallyStyle.muted)
                            .padding(6).background(RallyStyle.line.opacity(0.35), in: Capsule())
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(room.members) { player in playerTile(player) }
                        if room.members.count < room.capacity {
                            Image(systemName: "plus").font(.system(size: 24, weight: .light))
                                .foregroundStyle(RallyStyle.muted)
                                .frame(width: 46, height: 46)
                                .overlay(Circle().stroke(RallyStyle.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
                                .frame(maxWidth: .infinity, minHeight: 138)
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
                                .accessibilityLabel("Empty player slot")
                        }
                    }
                    controls
                }
                if let error = store.error { ErrorNotice(message: error) }
                Button(store.isHost ? "End room" : "Leave room") { confirmingLeave = true }
                    .font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 44).disabled(store.busy)
                    .accessibilityIdentifier("leaveRoomButton")
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .alert(store.isHost ? "End this room?" : "Heading out?", isPresented: $confirmingLeave) {
            Button(store.isHost ? "End room" : "Leave room", role: .destructive) { Task { await store.leave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.isHost ? "Everyone will return to the join screen." : "You can join again with the same room code.")
        }
        .accessibilityIdentifier("lobbyScreen")
    }

    private var roomTicket: some View {
        VStack(spacing: 14) {
            Eyebrow(text: room.locked ? "ROOM LOCKED" : "ROOM CODE")
            Text(room.displayCode)
                .font(.system(size: 47, weight: .semibold, design: .monospaced)).tracking(2)
                .minimumScaleFactor(0.7).lineLimit(1)
                .accessibilityLabel("Room code \(room.code.map(String.init).joined(separator: " "))")
                .accessibilityIdentifier("lobbyRoomCode")
            Rectangle().fill(RallyStyle.limeEdge.opacity(0.7)).frame(height: 1)
            HStack {
                Button {
                    UIPasteboard.general.string = room.code
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "square.on.square") }
                    .frame(maxWidth: .infinity, minHeight: 44)
                Rectangle().fill(RallyStyle.limeEdge).frame(width: 1, height: 24)
                ShareLink(item: "Join my Rally room: \(room.displayCode)\nrally://join/\(room.code)") {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            .font(RallyStyle.font(12, .semibold)).buttonStyle(.plain)
        }
        .padding(20).background(RallyStyle.lime, in: RoundedRectangle(cornerRadius: 22))
    }

    private func playerTile(_ player: Player) -> some View {
        VStack(spacing: 8) {
            AvatarView(index: player.avatar, size: 49).accessibilityHidden(true)
            HStack(spacing: 3) {
                Text(player.name).font(RallyStyle.font(14, .bold)).lineLimit(1)
                if player.id == store.me?.id { Text("(you)").font(RallyStyle.font(10)).foregroundStyle(RallyStyle.muted) }
            }
            Label(player.host ? "Host" : player.ready ? "Ready to go" : "Getting ready",
                  systemImage: player.host ? "crown" : player.ready ? "checkmark" : "clock")
                .font(RallyStyle.font(11)).foregroundStyle(player.ready ? RallyStyle.success : RallyStyle.muted)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 138)
        .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if store.isHost && !player.host {
                Button { Task { await store.remove(player) } } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).frame(width: 44, height: 44)
                }
                .foregroundStyle(RallyStyle.muted).disabled(store.busy)
                .accessibilityLabel("Remove \(player.name)")
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if store.isHost {
            VStack(spacing: 18) {
                Rectangle().fill(RallyStyle.line).frame(height: 1)
                Toggle("Lock the room", isOn: Binding(get: { room.locked }, set: { _ in Task { await store.setLocked() } }))
                    .font(RallyStyle.font(14, .semibold)).tint(RallyStyle.ink)
                    .disabled(store.busy || store.reconnecting).accessibilityIdentifier("roomLockToggle")
                Button { Task { await store.start() } } label: { ActionLabel(text: "Start session", busy: store.busy) }
                    .buttonStyle(PushButtonStyle()).disabled(!room.canStart || store.busy || store.reconnecting)
                    .accessibilityIdentifier("startSessionButton")
                Text(room.members.count < 2 ? "At least 2 players required." : room.canStart ? "Everyone is ready." : "\(room.readyCount) of \(room.members.count) ready.")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }
        } else {
            VStack(spacing: 18) {
                Label("Waiting for the host", systemImage: "clock")
                    .font(RallyStyle.font(14, .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(RallyStyle.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                Button { Task { await store.setReady() } } label: {
                    Label(store.me?.ready == true ? "Ready · tap to undo" : "I’m ready", systemImage: "checkmark")
                }
                .buttonStyle(PushButtonStyle(dark: store.me?.ready == true))
                .disabled(store.busy || store.reconnecting).accessibilityIdentifier("readyButton")
            }
        }
    }

    private var startedContent: some View {
        VStack(spacing: 24) {
            AvatarView(index: store.me?.avatar ?? 0, size: 125).rotationEffect(.degrees(-7)).accessibilityHidden(true)
            Text("Session started").font(RallyStyle.font(40, .heavy)).accessibilityAddTraits(.isHeader)
            Text("\(room.members.count) players").foregroundStyle(RallyStyle.muted)
            Text("Room \(room.displayCode)").font(RallyStyle.font(14, .semibold))
            if store.isHost {
                Button { Task { await store.reset() } } label: { ActionLabel(text: "Back to lobby", busy: store.busy) }
                    .buttonStyle(PushButtonStyle()).disabled(store.busy || store.reconnecting)
            } else {
                Text("Waiting for the host").font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 50)
    }
}
