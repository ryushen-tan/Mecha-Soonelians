import SwiftUI

private enum EntryTab: String, CaseIterable { case join = "Join", create = "Create" }

struct HomeView: View {
    @EnvironmentObject private var store: LobbyStore
    @Binding var invitationCode: String?
    @State private var tab = EntryTab.join
    @State private var code = ""
    @State private var joining = false
    @State private var settings = false
    @FocusState private var codeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            navigation.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if tab == .create || joining {
                        IdentityForm(creating: tab == .create, code: code, onCancel: { joining = false })
                    } else {
                        joinContent
                    }
                    if let error = store.error {
                        ErrorNotice(message: error)
                        Button("Connection settings") { settings = true }
                            .font(RallyStyle.font(14, .semibold))
                    }
                }
                .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .sheet(isPresented: $settings) { ServerSettingsView() }
        .onChange(of: invitationCode, initial: true) { _, value in
            if let value {
                tab = .join
                joining = false
                code = value
                invitationCode = nil
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            ForEach(EntryTab.allCases, id: \.self) { item in
                Button {
                    codeFocused = false
                    store.error = nil
                    joining = false
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { tab = item }
                } label: {
                    Text(item.rawValue)
                        .font(RallyStyle.font(14, tab == item ? .bold : .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if tab == item {
                                Capsule().fill(RallyStyle.surface.opacity(0.9))
                                    .shadow(color: RallyStyle.ink.opacity(0.08), radius: 3, y: 2)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .rallyHover(cornerRadius: 24)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .accessibilityIdentifier(item == .join ? "joinTab" : "createTab")
                .disabled(store.busy)
            }
        }
        .padding(6).rallyGlass().frame(maxWidth: 508)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App navigation")
        .frame(maxWidth: .infinity)
    }

    private var joinContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Brand()
            Text("A little code.\nA whole crew.")
                .font(RallyStyle.font(43, .heavy)).tracking(-1.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 8)
            CrewIllustration()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Got a room code?").font(RallyStyle.font(23, .bold)).tracking(-0.5)
                    Spacer()
                    Image(systemName: "arrow.down.left").accessibilityHidden(true)
                }
                TextField("000000", text: $code)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .tracking(6).multilineTextAlignment(.center)
                    .keyboardType(.numberPad).focused($codeFocused)
                    .rallyField().accessibilityLabel("Room code")
                    .accessibilityIdentifier("roomCodeInput")
                    .onChange(of: code) { _, value in
                        code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    }
                Button {
                    codeFocused = false
                    store.error = nil
                    joining = true
                } label: { ActionLabel(text: "Join the room") }
                .buttonStyle(PushButtonStyle()).disabled(code.count != 6)
                .accessibilityIdentifier("joinRoomButton")
            }
            .padding(22)
            .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(RallyStyle.line, lineWidth: 1))
        }
    }
}

private struct IdentityForm: View {
    @EnvironmentObject private var store: LobbyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let creating: Bool
    let code: String
    let onCancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !creating {
                HStack {
                    Button(action: onCancel) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("Back to join")
                    Spacer()
                    Button("Cancel", action: onCancel)
                }.disabled(store.busy)
                Text("Join room \(code.prefix(3)) \(code.suffix(3))")
                    .font(RallyStyle.font(32, .bold)).accessibilityAddTraits(.isHeader)
            }
            AvatarView(index: store.avatar, size: 100)
                .keyframeAnimator(initialValue: -5.0, trigger: store.avatar) { content, angle in
                    content.rotationEffect(.degrees(reduceMotion ? -5 : angle), anchor: .bottom)
                } keyframes: { _ in
                    CubicKeyframe(-16.0, duration: 0.10)
                    CubicKeyframe(12.0, duration: 0.14)
                    CubicKeyframe(-10.0, duration: 0.13)
                    CubicKeyframe(1.0, duration: 0.12)
                    CubicKeyframe(-5.0, duration: 0.15)
                }
                .frame(maxWidth: .infinity).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Pick your face").font(RallyStyle.font(14, .semibold))
                HStack(spacing: 0) {
                    ForEach(0..<6) { index in
                        Button { store.avatar = index } label: {
                            AvatarView(index: index, size: 32, selected: store.avatar == index)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .rallyHover(cornerRadius: 14)
                        .accessibilityLabel(RallyStyle.avatarNames[index] + " avatar")
                        .accessibilityAddTraits(store.avatar == index ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Nickname").font(RallyStyle.font(14, .semibold))
                TextField("Your nickname", text: $store.nickname)
                    .font(RallyStyle.font(18, .medium)).textContentType(.nickname)
                    .autocorrectionDisabled().submitLabel(.done).focused($nameFocused)
                    .rallyField().accessibilityLabel("Nickname").accessibilityIdentifier("nicknameInput")
                    .onSubmit { nameFocused = false }
                Text("1–20 characters").font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }
            Button {
                nameFocused = false
                Task { _ = await store.enter(code: creating ? nil : code) }
            } label: {
                ActionLabel(text: creating ? "Create room" : "Join room", busy: store.busy)
            }
            .buttonStyle(PushButtonStyle()).disabled(store.busy || !store.validName)
            .accessibilityIdentifier("confirmEntryButton")
            .padding(.top, 6)
        }
        .disabled(store.busy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(creating ? "Create a room" : "Join a room")
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
