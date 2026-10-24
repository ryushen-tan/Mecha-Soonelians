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

    var body: some View {
        NavigationStack {
            List {
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
            .onAppear { hasHouse = HouseStore.hasHouse }
        }
    }
}
