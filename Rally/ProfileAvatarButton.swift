import SwiftUI

struct ProfileAvatarButton: View {
    let name: String
    let color: Int
    @State private var showsPreview = false

    var body: some View {
        Button { showsPreview = true } label: {
            HStack(spacing: 12) {
                PlayerAvatar(name: name, color: color, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your avatar").font(JellyStyle.body(16))
                    Text("View avatar").font(JellyStyle.body(13)).foregroundStyle(JellyStyle.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14))
            }
            .foregroundStyle(JellyStyle.ink)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profilePhotoPreview")
        .sheet(isPresented: $showsPreview) { ProfileAvatarPreview(name: name) }
    }
}
