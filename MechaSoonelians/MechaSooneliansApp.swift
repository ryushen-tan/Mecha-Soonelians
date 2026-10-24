import SwiftUI

@main
struct MechaSooneliansApp: App {
    @StateObject private var store = LobbyStore()

    var body: some Scene {
        WindowGroup {
            CharacterLaunchGate { RootView() }.environmentObject(store)
                .buttonStyle(HoverButtonStyle())
                .tint(RallyStyle.ink)
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LobbyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var invitationCode: String?

    var body: some View {
        JellyExperienceView(invitationCode: $invitationCode)
        .foregroundStyle(RallyStyle.ink)
        .environment(\.gameConnection, store.membership.map { membership in
            GameConnection(server: membership.server, code: membership.code, memberID: membership.memberID,
                token: membership.token, isHost: store.isHost)
        })
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { store.reloadServerAddress() }
        }
        .task(id: "\(scenePhase == .active)-\(store.membership?.token ?? "")") {
            guard scenePhase == .active, store.membership != nil else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(1.2)) } catch { break }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { store.room?.started == true }, set: { _ in })) {
            if let membership = store.membership, let me = store.me {
                OnlineGameScreen(connection: GameConnection(server: membership.server, code: membership.code,
                    memberID: membership.memberID, token: membership.token, isHost: store.isHost),
                    name: me.name, avatar: me.avatar)
            }
        }
        .onOpenURL { url in
            guard url.scheme == "rally", url.host == "join", store.membership == nil else { return }
            let code = url.lastPathComponent
            guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
            invitationCode = code
        }
    }
}

/// The AR round, shown for as long as the room is started.
struct OnlineGameScreen: View {
    @EnvironmentObject private var store: LobbyStore
    @StateObject private var session: GameSession

    init(connection: GameConnection, name: String, avatar: Int) {
        _session = StateObject(wrappedValue: GameSession(connection: connection, name: name, avatar: avatar))
    }

    var body: some View {
        GameView(session: session) {
            // The host sends everyone back to the lobby; anyone else leaves the room.
            Task { if store.isHost { await store.reset() } else { await store.leave() } }
        }
        .environmentObject(store)
    }
}
