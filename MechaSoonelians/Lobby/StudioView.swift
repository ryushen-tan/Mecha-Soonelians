import RoomPlan
import SwiftUI

enum StudioRoute: Hashable {
    case capture
    case scan
    case character(String)
    case player(String)
}

struct StudioView: View {
    @State private var hasHouse = HouseStore.hasHouse
    @State private var players: [SavedPlayer] = []
    @State private var characters: [CharacterAsset] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Eyebrow(text: "YOUR REAL-WORLD PLAYGROUND")
                Text("Your room.\nYour characters.")
                    .font(RallyStyle.font(38, .heavy)).tracking(-1.5)
                    .accessibilityAddTraits(.isHeader)
                Text("Scan the space. Capture your crew. Give everyone a pose.")
                    .font(RallyStyle.font(16)).foregroundStyle(RallyStyle.muted)
                NavigationLink(value: StudioRoute.capture) {
                    studioCard(title: "Make a player", subtitle: "Auto cutout · depth · pose editor", icon: "figure.stand", color: RallyStyle.lime)
                }
                .buttonStyle(.plain).rallyHover(cornerRadius: 22).accessibilityIdentifier("makePlayerButton")
                if RoomCaptureSession.isSupported {
                    NavigationLink(value: StudioRoute.scan) {
                        studioCard(title: hasHouse ? "Scan a new house" : "Scan your house", subtitle: hasHouse ? "Replaces the house saved on this device" : "Map rooms together with RoomPlan", icon: "house", color: RallyStyle.cyan)
                    }
                    .buttonStyle(.plain).rallyHover(cornerRadius: 22)
                } else {
                    studioCard(title: "Scan your house", subtitle: "RoomPlan needs a supported LiDAR iPhone or iPad. Player samples work here.", icon: "house", color: RallyStyle.cyan, available: false)
                }
                if hasHouse {
                    Label("House saved on this device", systemImage: "checkmark.circle.fill")
                        .font(RallyStyle.font(14, .semibold)).foregroundStyle(RallyStyle.success)
                }
                if !characters.isEmpty {
                    Text("3D characters").font(RallyStyle.font(23, .bold))
                    ForEach(characters) { character in
                        NavigationLink(value: StudioRoute.character(character.id)) {
                            HStack(spacing: 16) {
                                if let image = character.preview {
                                    Image(uiImage: image).resizable().scaledToFit().frame(width: 70, height: 90)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Character \(character.id.prefix(4))").font(RallyStyle.font(17, .bold))
                                    Text(character.hasModel ? "Rotate & edit 3D pose" : "Resume generation")
                                        .font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
                                }
                                Spacer()
                                Image(systemName: "cube.transparent")
                            }
                            .padding(16).background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line))
                        }.buttonStyle(.plain).rallyHover(cornerRadius: 18).accessibilityIdentifier("character_\(character.id)")
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Your players").font(RallyStyle.font(23, .bold))
                        Spacer()
                        Text("\(players.count)").font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(RallyStyle.muted)
                    }
                    if players.isEmpty {
                        Text("Your first character is one scan away. Try the human depth sample to get started.")
                            .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                            ForEach(players) { player in
                                NavigationLink(value: StudioRoute.player(player.id)) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Image(uiImage: player.preview).resizable().scaledToFit().frame(height: 140)
                                            .frame(maxWidth: .infinity)
                                        Text("Player \(player.id.prefix(4))").font(RallyStyle.font(14, .bold))
                                        Text(player.createdAt, style: .date).font(RallyStyle.font(12))
                                            .foregroundStyle(RallyStyle.muted)
                                    }
                                    .padding(14).background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(RallyStyle.line))
                                }.buttonStyle(.plain).rallyHover(cornerRadius: 18)
                            }
                        }
                    }
                }
                Text("Captures stay local unless you choose Tripo generation or publish a disguise to your lobby. Open a 3D character to pose, paint, place clones, and play in your room.")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .foregroundStyle(RallyStyle.ink)
        .navigationTitle("Studio").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: StudioRoute.self) { route in
            switch route {
            case .capture:
                CaptureEditorView()
            case .scan:
                ScanView { hasHouse = true }
            case .character(let id):
                if let character = characters.first(where: { $0.id == id }) {
                    Character3DView(asset: character)
                }
            case .player(let id):
                if let player = players.first(where: { $0.id == id }) {
                    SavedPlayerView(player: player)
                }
            }
        }
        .onAppear {
            hasHouse = HouseStore.hasHouse
            players = SavedPlayer.load(from: HouseStore.documents.appendingPathComponent("Players"))
            characters = CharacterAsset.all()
        }
    }

    private func studioCard(title: String, subtitle: String, icon: String, color: Color, available: Bool = true) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 26, weight: .medium))
                .frame(width: 58, height: 66).background(color, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(RallyStyle.font(20, .bold))
                Text(subtitle).font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
            }
            Spacer(minLength: 0)
            if available {
                Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .semibold))
            }
        }
        .padding(18).background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(RallyStyle.line))
    }
}

struct SavedPlayer: Identifiable {
    let id: String
    let preview: UIImage
    let createdAt: Date
    let directory: URL

    static func load(from directory: URL) -> [SavedPlayer] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { folder in
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("rig.json").path),
                  let preview = UIImage(contentsOfFile: folder.appendingPathComponent("posed.png").path)
                    ?? UIImage(contentsOfFile: folder.appendingPathComponent("cutout.png").path) else { return nil }
            return SavedPlayer(id: folder.lastPathComponent, preview: preview,
                               createdAt: (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                               directory: folder)
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

private struct SavedPlayerView: View {
    let player: SavedPlayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Eyebrow(text: "SAVED CHARACTER")
                Image(uiImage: player.preview).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 360)
                    .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                Text("Your character, ready to share.").font(RallyStyle.font(28, .bold))
                ShareLink(item: player.directory.appendingPathComponent(FileManager.default.fileExists(atPath: player.directory.appendingPathComponent("posed.png").path) ? "posed.png" : "cutout.png")) {
                    ActionLabel(text: "Share cutout")
                }.buttonStyle(PushButtonStyle())
                Text("The original photo, mask, rig and available depth are kept in Files → On My iPhone → Rally → Players. This is a saved preview; start a new capture to make another pose.")
                    .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
        .navigationTitle("Player \(player.id.prefix(4))").navigationBarTitleDisplayMode(.inline)
    }
}
