import SwiftUI

/// Make your chameleon: a front-camera 360° turnaround mapped onto the smooth chameleon body.
/// Made once, then placed, posed and painted every round.
struct ChameleonStudioView: View {
    private enum Step { case intro, capturing, building }

    @StateObject private var capture = ChameleonCapture()
    @State private var step = Step.intro
    @State private var sculptor: GhostSculptor?
    @State private var saved = false
    @State private var saveError: String?
    @AppStorage("chameleonFaceless") private var faceless = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch step {
            case .intro: intro
            case .capturing: capturing
            case .building:
                if let sculptor {
                    Ghost3DView(sculptor: sculptor, placeTitle: saved ? "Done" : "Saving…",
                                onCancel: { restart() })
                }
            }
        }
        .foregroundStyle(RallyStyle.ink)
        .navigationTitle("Your chameleon")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { capture.stop() }
        .onChange(of: capture.stage) {
            if capture.stage == .done { build() }
        }
        .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: { Text(saveError ?? "") }
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Eyebrow(text: "MAKE YOUR CHAMELEON")
                Text("Spin once, hide forever.").font(RallyStyle.font(32, .heavy)).tracking(-1)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Prop your phone up at waist height, screen facing you.", systemImage: "iphone")
                    Label("Step back until your whole body fits, arms out a little.", systemImage: "figure.arms.open")
                    Label("At each beep, turn a little to your right. Eight turns makes a full circle.", systemImage: "arrow.clockwise")
                }
                .font(RallyStyle.font(15, .medium))
                Toggle("Keep my face off (Meccha style)", isOn: $faceless)
                    .font(RallyStyle.font(14, .semibold)).tint(RallyStyle.ink)
                Text("Your colors get mapped onto a 1 m chameleon body. It looks like your outfit, not a photo of you.")
                    .font(RallyStyle.font(12)).foregroundStyle(RallyStyle.muted)
                Text("Chameleon body: “MECCHA CHAMELEON Player rig” by BlueMan, CC BY 4.0.")
                    .font(RallyStyle.font(11)).foregroundStyle(RallyStyle.muted)
                Button {
                    step = .capturing
                    capture.start()
                } label: { ActionLabel(text: ChameleonStore.hasChameleon ? "Make a new one" : "Open the camera") }
                .buttonStyle(PushButtonStyle())
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .background(RallyStyle.paper.ignoresSafeArea())
    }

    private var capturing: some View {
        ZStack {
            TurnaroundPreview(session: capture.session).ignoresSafeArea()
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    switch capture.stage {
                    case .framing:
                        Text(capture.fullBodyInView ? "Looking good. Ready when you are." : "Step back until your whole body fits.")
                            .font(RallyStyle.font(17, .bold))
                        Button { Task { await capture.run() } } label: { ActionLabel(text: "Start the spin") }
                            .buttonStyle(PushButtonStyle())
                            .disabled(!capture.fullBodyInView)
                    case .countdown(let second):
                        Text("\(second)").font(RallyStyle.font(64, .heavy))
                    case .shooting(let shot):
                        Text(shot == 0 ? "Face the phone" : "Turn a little to your right")
                            .font(RallyStyle.font(20, .bold))
                        Text("Shot \(shot + 1) of \(ChameleonCapture.shots)").font(RallyStyle.font(13)).foregroundStyle(RallyStyle.muted)
                    case .processing:
                        HStack { ProgressView(); Text("Cutting you out…").font(RallyStyle.font(16, .semibold)) }
                    case .done:
                        Text("Got it!").font(RallyStyle.font(20, .bold))
                    case .failed(let message):
                        ErrorNotice(message: message)
                        Button { restart() } label: { ActionLabel(text: "Try again") }
                            .buttonStyle(PushButtonStyle())
                    }
                }
                .padding(20).frame(maxWidth: .infinity)
                .background(RallyStyle.surface, in: RoundedRectangle(cornerRadius: 24))
                .padding(16)
            }
        }
    }

    private func build() {
        let sculptor = GhostSculptor(views: capture.views, faceless: faceless)
        self.sculptor = sculptor
        step = .building
        // Saving keeps the mannequin un-posed and unpainted; that happens each round when hiding.
        sculptor.onChameleon = { model in
            do {
                try ChameleonStore.save(model)
                saved = true
            } catch {
                saveError = error.localizedDescription
            }
        }
        // The button in the 3D view finishes the studio.
        sculptor.onExported = { _ in dismiss() }
    }

    private func restart() {
        sculptor = nil
        saved = false
        capture.stop()
        step = .intro
    }
}
