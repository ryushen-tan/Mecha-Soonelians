import SwiftUI

@main
struct RallyApp: App {
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
        Group {
            if let room = store.room {
                LobbyView(room: room)
            } else if store.membership != nil {
                VStack(spacing: 24) {
                    Brand()
                    ProgressView().controlSize(.large)
                    Text(store.reconnecting ? "Trying to reconnect…" : "Finding your room…")
                        .font(RallyStyle.font(24, .bold))
                    Text("You’ll return to your seat when the server responds.")
                        .foregroundStyle(RallyStyle.muted).multilineTextAlignment(.center)
                    Button("Leave this room") { Task { await store.leave() } }.disabled(store.busy)
                }
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(RallyStyle.paper)
            } else {
                HomeView(invitationCode: $invitationCode)
            }
        }
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
        .onOpenURL { url in
            guard url.scheme == "rally", url.host == "join", store.membership == nil else { return }
            let code = url.lastPathComponent
            guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
            invitationCode = code
        }
    }
}
