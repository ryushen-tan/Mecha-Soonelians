import SwiftUI
import UIKit

/// Matches the entered name to the bundled directory without guessing partial names.
enum ProfilePhotos {
    enum AvatarView: Int, CaseIterable, Identifiable {
        case front, angle, back

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .front: return "Front"
            case .angle: return "Angle"
            case .back: return "Back"
            }
        }
    }

    struct Entry: Decodable {
        let name: String
        let file: String
    }

    static let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "profiles", withExtension: "json", subdirectory: "ProfilePhotos"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }()

    private static let byName = Dictionary(grouping: entries, by: { normalizedName($0.name) })
    private static let images = NSCache<NSString, UIImage>()
    private static let avatarImages: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    static func filename(for name: String) -> String? {
        guard let matches = byName[normalizedName(name)], matches.count == 1 else { return nil }
        return matches[0].file
    }

    static func image(for name: String) -> UIImage? {
        guard let filename = filename(for: name) else { return nil }
        if let image = images.object(forKey: filename as NSString) { return image }
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "ProfilePhotos"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: filename as NSString)
        return image
    }

    static func avatarImage(for name: String, view: AvatarView = .front) -> UIImage? {
        guard let filename = filename(for: name) else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        let key = "\(stem)/\(view.rawValue)" as NSString
        if let image = avatarImages.object(forKey: key) { return image }
        guard let url = Bundle.main.url(forResource: stem, withExtension: "png", subdirectory: "ProfilePhotos/AIAvatars"),
              let sheet = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        // Each sheet contains three views. Integer boundaries include every column
        // even when the sheet width is not divisible by three.
        let left = sheet.width * view.rawValue / 3
        let right = sheet.width * (view.rawValue + 1) / 3
        guard let crop = sheet.cropping(to: CGRect(x: left, y: 0, width: right - left, height: sheet.height)) else { return nil }
        // Draw an independent image so a cached view does not retain the full sheet.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: crop.width, height: crop.height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
        }
        avatarImages.setObject(image, forKey: key, cost: crop.width * crop.height * 4)
        return image
    }

    static func faceTexture(for name: String) -> UIImage? {
        generatedImage(for: name, suffix: "-face")
    }

    private static func generatedImage(for name: String, suffix: String) -> UIImage? {
        guard let filename = filename(for: name) else { return nil }
        let stem = (filename as NSString).deletingPathExtension + suffix
        let key = "avatar/" + stem
        if let image = images.object(forKey: key as NSString) { return image }
        guard let url = Bundle.main.url(forResource: stem, withExtension: "png", subdirectory: "ProfilePhotos/Avatars"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: key as NSString)
        return image
    }
}

struct PlayerAvatar: View {
    let name: String
    let color: Int
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let image = ProfilePhotos.avatarImage(for: name) {
                Image(uiImage: image).resizable().scaledToFit()
                    .background(Color(white: 0.61))
            } else {
                Circle().fill(JellyStyle.colors[min(5, max(0, color))])
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("Avatar for \(name)")
    }
}

struct ProfileAvatarPreview: View {
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedView: ProfilePhotos.AvatarView = .front

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = ProfilePhotos.avatarImage(for: name, view: selectedView) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("\(selectedView.title) avatar view for \(name)")
                        .accessibilityIdentifier("profileAvatarImage")
                    Picker("Avatar view", selection: $selectedView) {
                        ForEach(ProfilePhotos.AvatarView.allCases) { view in
                            Text(view.title).tag(view)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("profileAvatarViewPicker")
                } else {
                    ContentUnavailableView("Avatar unavailable", systemImage: "person.crop.circle")
                }
            }
            .padding(24)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: name) { selectedView = .front }
        }
    }
}
