import SwiftUI
import RoomPlan

@main
struct MechaSooneliansApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var hasHouse = HouseStore.hasHouse
    @State private var path: [String] = ProcessInfo.processInfo.arguments.contains("--mock-editor") ? ["editor"] : []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: "editor") {
                        Label("Capture and pose a player", systemImage: "figure.stand")
                    }
                } footer: {
                    Text("Detect people, remove backgrounds, and edit a 2D pose. Try the human depth sample or scan someone with your camera.")
                }
                Section {
                    NavigationLink("Scan the house") {
                        ScanView(onSaved: { hasHouse = true })
                    }
                    .disabled(!RoomCaptureSession.isSupported)
                } footer: {
                    if !RoomCaptureSession.isSupported {
                        Text("Scanning needs an iPhone or iPad with LiDAR.")
                    } else if hasHouse {
                        Text("A scan is saved. Find it in Files › On My iPhone › Mecha Soonelians › House. Scanning again replaces it.")
                    } else {
                        Text("Scan room by room without closing the app, then tap Finish house.")
                    }
                }
            }
            .navigationTitle("Mecha Soonelians")
            .navigationDestination(for: String.self) { _ in
                CaptureEditorView()
            }
            .onAppear { hasHouse = HouseStore.hasHouse }
        }
    }
}
