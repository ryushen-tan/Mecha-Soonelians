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
        .onOpenURL { url in
            guard url.scheme == "rally", url.host == "join", store.membership == nil else { return }
            let code = url.lastPathComponent
            guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
            invitationCode = code
        }
    }
}
