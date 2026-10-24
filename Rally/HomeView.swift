import SwiftUI

enum JellyEntry: Equatable {
    case landing, code, host, join(String)
}

struct HomeView: View {
    @EnvironmentObject private var store: LobbyStore
    @EnvironmentObject private var audio: JellyAudio
    @Binding var entry: JellyEntry
    @Binding var invitationCode: String?
    @State private var code = ""
    @State private var settings = false
    @FocusState private var focused: Field?
    private enum Field { case code, name }

    var body: some View {
        JellyCard {
            switch entry {
            case .landing: EmptyView()
            case .code: codeCard
            case .host: identityCard(creating: true, roomCode: nil)
            case .join(let code): identityCard(creating: false, roomCode: code)
            }
            if let error = store.error {
                JellyNotice(message: error)
                Button("Connection settings") { settings = true }
                    .font(JellyStyle.body(13)).underline().buttonStyle(.plain)
                    .frame(minHeight: 44)
            }
        }
        .foregroundStyle(JellyStyle.ink)
        .sheet(isPresented: $settings) { ServerSettingsView() }
        .onChange(of: invitationCode, initial: true) { _, value in
            guard let value else { return }
            code = value; entry = .code; invitationCode = nil
        }
        .onChange(of: entry) { _, _ in focused = nil; store.error = nil }
    }

    private var codeCard: some View {
        Group {
            (Text("Mecha ") + Text("Soonelians").foregroundColor(JellyStyle.blue))
                .font(JellyStyle.display(34)).accessibilityAddTraits(.isHeader)
                .lineLimit(2).minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
            Text("ENTER CODE").font(JellyStyle.body(12)).tracking(1.7).foregroundStyle(JellyStyle.muted)
            TextField("000000", text: $code)
                .font(JellyStyle.display(36)).tracking(4).multilineTextAlignment(.center)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .keyboardType(.numberPad).focused($focused, equals: .code)
                .modifier(JellyField(focused: focused == .code))
                .accessibilityLabel("Room code").accessibilityIdentifier("roomCodeInput")
                .onChange(of: code) { old, value in
                    code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if old != code { audio.key(.type) }
                }
            Button {
                audio.key(.enter); entry = .join(code)
            } label: {
                HStack { Text("Join"); Spacer(); Image(systemName: "arrow.right") }
                    .font(JellyStyle.display(20))
            }
            .buttonStyle(JellyButtonStyle(fullWidth: true))
            .disabled(code.count != 6).accessibilityIdentifier("joinRoomButton")
            HStack {
                Button("host a game") { entry = .host }
                    .accessibilityIdentifier("createTab")
                Spacer()
                Button("back") { entry = .landing }
                    .accessibilityIdentifier("backToSceneButton")
            }
            .font(JellyStyle.body(13)).underline().foregroundStyle(JellyStyle.muted)
            .buttonStyle(.plain).frame(minHeight: 44)
        }
    }

    private func identityCard(creating: Bool, roomCode: String?) -> some View {
        Group {
            Text(creating ? "Host a game" : "Join the room")
                .font(JellyStyle.display(28)).accessibilityAddTraits(.isHeader)
            if let roomCode {
                Text(roomCode).font(JellyStyle.display(32)).tracking(6)
                    .accessibilityLabel("Room code " + roomCode.map(String.init).joined(separator: " "))
            }
            Text("YOUR NAME").font(JellyStyle.body(12)).tracking(1).foregroundStyle(JellyStyle.muted)
            TextField("Your nickname", text: $store.nickname)
                .font(JellyStyle.body(18)).textContentType(.nickname)
                .autocorrectionDisabled().submitLabel(.go).focused($focused, equals: .name)
                .modifier(JellyField(focused: focused == .name))
                .accessibilityLabel("Nickname").accessibilityIdentifier("nicknameInput")
                .onChange(of: store.nickname) { _, _ in audio.key(.type) }
                .onSubmit { if store.validName { enter(roomCode) } }
            Text("1–20 characters").font(JellyStyle.body(12)).foregroundStyle(JellyStyle.muted)
            Text("PICK A COLOR").font(JellyStyle.body(12)).tracking(1).foregroundStyle(JellyStyle.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { colorChoices }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) { colorChoices }
            }
            Button { enter(roomCode) } label: {
                HStack {
                    Text(creating ? "Create room" : "Join room")
                    if store.busy { ProgressView().tint(.white) }
                }
            }
            .buttonStyle(JellyButtonStyle(fullWidth: true))
            .disabled(store.busy || !store.validName).accessibilityIdentifier("confirmEntryButton")
            HStack {
                Button("Back") { entry = .code }.accessibilityIdentifier("backToCodeButton")
                Spacer()
                Button { settings = true } label: { Image(systemName: "network") }
                    .accessibilityLabel("Connection settings")
            }
            .buttonStyle(JellyButtonStyle(kind: .ghost)).disabled(store.busy)
        }
        .disabled(store.busy)
    }

    private var colorChoices: some View {
        ForEach(0..<6) { index in
            Button { store.avatar = index; audio.key(.click) } label: {
                Circle().fill(JellyStyle.colors[index])
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder(store.avatar == index ? JellyStyle.ink : .clear, lineWidth: 3))
                    .overlay {
                        if store.avatar == index {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(index == 1 ? .white : JellyStyle.ink)
                        }
                    }
                    .frame(width: 44, height: 44).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).hoverEffect(.highlight)
            .accessibilityLabel(JellyStyle.colorNames[index] + " avatar")
            .accessibilityAddTraits(store.avatar == index ? .isSelected : [])
        }
    }

    private func enter(_ code: String?) {
        focused = nil; audio.key(.enter)
        Task {
            if await store.enter(code: code), code != nil, store.me?.ready == false {
                await store.setReady()
            }
        }
    }
}

struct ServerSettingsView: View {
    @EnvironmentObject private var store: LobbyStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://lobby.example.com", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityLabel("Server address")
                } header: { Text("Server address") } footer: {
                    Text("Everyone needs the same server. In Simulator, use http://localhost:3000. On an iPhone, use your Mac’s Wi-Fi address printed by the server.")
                }
                if let error { Section { ErrorNotice(message: error) } }
                Button {
                    checking = true
                    error = nil
                    Task {
                        defer { checking = false }
                        do {
                            let url = try ServerAddress.parse(address)
                            struct Health: Decodable { let status: String; let service: String }
                            let result: Health = try await LobbyAPI(baseURL: url).request("health")
                            guard result.status == "ok", result.service == "rally" else {
                                throw LobbyError(status: 0, message: "This is not a Rally server.")
                            }
                            store.serverAddress = url.absoluteString
                            store.error = nil
                            dismiss()
                        } catch {
                            self.error = (error as? LobbyError)?.message ?? "Couldn’t connect. Check the address and make sure the server is running."
                        }
                    }
                } label: {
                    HStack { Text("Test connection & save"); Spacer(); if checking { ProgressView() } }
                }.disabled(checking)
            }
            .navigationTitle("Connection settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.disabled(checking) } }
            .interactiveDismissDisabled(checking)
            .onAppear { address = store.serverAddress }
        }
    }
}
