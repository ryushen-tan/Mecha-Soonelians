import SwiftUI
import RoomPlan

@main
struct MechaSooneliansApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .buttonStyle(HoverButtonStyle())
                .tint(RallyStyle.ink)
                .preferredColorScheme(.light)
        }
    }
}

private enum EntryTab: String, CaseIterable {
    case join = "Join", host = "Host"
}

private enum Route: Hashable {
    case join, host, scan, mapTest, studio, chameleon
}

/// Home, in Rally's style: pick a face and a name, then join a game nearby or host one.
/// Hosting needs a house scan, so the Host tab also holds the scanner.
struct ContentView: View {
    @State private var hasHouse = HouseStore.hasHouse
    @State private var hasChameleon = ChameleonStore.hasChameleon
    @State private var tab = EntryTab.join
    @State private var path: [Route] = ProcessInfo.processInfo.arguments.contains("--mock-editor") ? [.studio] : []
    @AppStorage("playerName") private var name = ""
    @AppStorage("playerAvatar") private var avatar = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var validName: Bool { (1...20).contains(trimmedName.count) }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                navigation.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Brand()
                        if tab == .join { joinContent } else { hostContent }
                    }
                    .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(RallyStyle.paper.ignoresSafeArea())
            .foregroundStyle(RallyStyle.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .join: JoinGameView(name: trimmedName, avatar: avatar)
                case .host: HostGameView(name: trimmedName, avatar: avatar)
                case .scan: ScanView(onSaved: { hasHouse = true })
                case .mapTest: MapTestView()
                case .studio: CaptureEditorView()
                case .chameleon: ChameleonStudioView()
                }
            }
            .onAppear {
                hasHouse = HouseStore.hasHouse
                hasChameleon = ChameleonStore.hasChameleon
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            ForEach(EntryTab.allCases, id: \.self) { item in
                Button {
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
            }
        }
        .padding(6).rallyGlass().frame(maxWidth: 508)
        .frame(maxWidth: .infinity)
    }

    private var joinContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Paint yourself.\nDisappear.")
                .font(RallyStyle.font(43, .heavy)).tracking(-1.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 8)
            CrewIllustration()
            card {
                identity
                Button { path.append(.join) } label: { ActionLabel(text: "Find games nearby") }
                    .buttonStyle(PushButtonStyle()).disabled(!validName)
                Text("Everyone needs to be on the same Wi-Fi as the host.")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }
        }
    }

    private var hostContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Host a round")
                .font(RallyStyle.font(32, .bold)).accessibilityAddTraits(.isHeader)
            card {
                Eyebrow(text: hasHouse ? "HOUSE SCANNED" : "STEP 1 · SCAN YOUR HOUSE")
                Text(hasHouse
                     ? "Your house is ready. Scan again if you move furniture around."
                     : "Walk each room with the scanner. Players' phones use this map to find hiding spots.")
                    .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if RoomCaptureSession.isSupported {
                    Button { path.append(.scan) } label: {
                        ActionLabel(text: hasHouse ? "Scan again" : "Scan the house")
                    }
                    .buttonStyle(PushButtonStyle(dark: hasHouse))
                } else {
                    ErrorNotice(message: "Scanning needs an iPhone or iPad with LiDAR.")
                }
                if hasHouse {
                    Button("Test the house map") { path.append(.mapTest) }
                        .font(RallyStyle.font(14, .semibold))
                }
            }
            card {
                Eyebrow(text: "STUDIO")
                Text("Capture someone, cut them out and pose them, or turn them into a 3D character.")
                    .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { path.append(.studio) } label: { ActionLabel(text: "Make a player") }
                    .buttonStyle(PushButtonStyle(dark: true))
            }
            card {
                identity
                Button { path.append(.host) } label: { ActionLabel(text: "Create room") }
                    .buttonStyle(PushButtonStyle()).disabled(!validName || !hasHouse)
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 18) {
            AvatarView(index: avatar, size: 100)
                .keyframeAnimator(initialValue: -5.0, trigger: avatar) { content, angle in
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
                        Button { avatar = index } label: {
                            AvatarView(index: index, size: 32, selected: avatar == index)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .rallyHover(cornerRadius: 14)
                        .accessibilityLabel(RallyStyle.avatarNames[index] + " avatar")
                        .accessibilityAddTraits(avatar == index ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Nickname").font(RallyStyle.font(14, .semibold))
                TextField("Your nickname", text: $name)
                    .font(RallyStyle.font(18, .medium)).textContentType(.nickname)
                    .autocorrectionDisabled().submitLabel(.done)
                    .rallyField().accessibilityLabel("Nickname")
                Text("1–20 characters").font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }
            Button { path.append(.chameleon) } label: {
                HStack {
                    Image(systemName: "figure.stand").accessibilityHidden(true)
                    Text(hasChameleon ? "Your chameleon ✅ · remake" : "Make your chameleon")
                    Spacer()
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
                .font(RallyStyle.font(15, .semibold))
                .padding(14)
                .background(RallyStyle.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(22)
            .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(RallyStyle.line, lineWidth: 1))
    }
}
