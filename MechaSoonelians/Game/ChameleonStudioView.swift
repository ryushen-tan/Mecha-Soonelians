import SwiftUI

/// Make your chameleon: four front-camera photos (front, side, back, side) mapped part by part onto the smooth chameleon body.
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
                Text("Four photos, hide forever.").font(RallyStyle.font(32, .heavy)).tracking(-1)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Prop your phone up at waist height, screen facing you.", systemImage: "iphone")
                    Label("Walk back until your whole body fits. It starts by itself and talks you through it.", systemImage: "figure.arms.open")
                    Label("It takes 4 photos: front, side, back, other side. Just turn right when it tells you.", systemImage: "arrow.clockwise")
                    Label("Good, even light works best. Hold your arms out a little like the outline.", systemImage: "light.max")
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

    /// The four photos: label, outline symbol (flipped for the other side), and what to do.
    private static let steps: [(label: String, symbol: String, flipped: Bool, title: String, detail: String)] = [
        ("FRONT", "figure.arms.open", false, "Face the phone", "Arms out a little. Stand still."),
        ("SIDE", "figure.walk", false, "Turn to your right", "Your side faces the phone. Stand still."),
        ("BACK", "figure.arms.open", false, "Turn right again", "Your back faces the phone. Stand still."),
        ("SIDE", "figure.walk", true, "Turn right once more", "Your other side faces the phone. Stand still."),
    ]

    private var currentStep: Int? {
        switch capture.stage {
        case .photo(let index, _): index
        case .countdown, .framing: 0
        default: nil
        }
    }

    private var capturing: some View {
        ZStack {
            TurnaroundPreview(session: capture.session).ignoresSafeArea()
            // The outline to match: changes for each photo.
            if let step = currentStep {
                let info = Self.steps[step]
                VStack(spacing: 6) {
                    Image(systemName: info.symbol)
                        .resizable().scaledToFit()
                        .scaleEffect(x: info.flipped ? -1 : 1, y: 1)
                        .frame(maxHeight: 400)
                    Text(info.label).font(RallyStyle.font(28, .heavy)).tracking(4)
                }
                .foregroundStyle(.white.opacity(0.45))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(.easeInOut(duration: 0.3), value: step)
            }
            if case .photo(_, let second) = capture.stage {
                Text(second > 0 ? "\(second)" : "📸")
                    .font(RallyStyle.font(120, .heavy))
                    .foregroundStyle(RallyStyle.lime)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }
            VStack {
                progress
                Spacer()
                VStack(spacing: 10) {
                    switch capture.stage {
                    case .framing:
                        Text(framingHint)
                            .font(RallyStyle.font(18, .bold))
                            .multilineTextAlignment(.center)
                        Button { Task { await capture.run() } } label: { ActionLabel(text: "Start now") }
                            .buttonStyle(PushButtonStyle())
                            .disabled(!capture.fullBodyInView)
                    case .countdown:
                        Text("Get ready…").font(RallyStyle.font(22, .bold))
                        Text("Listen for the steps. Keep your arms out a little.")
                            .font(RallyStyle.font(14)).foregroundStyle(RallyStyle.muted)
                    case .photo(let index, _):
                        HStack(spacing: 10) {
                            if index > 0 { Image(systemName: "arrow.turn.up.right").font(.system(size: 22, weight: .bold)) }
                            Text(Self.steps[index].title).font(RallyStyle.font(24, .heavy))
                        }
                        Text(Self.steps[index].detail).font(RallyStyle.font(15)).foregroundStyle(RallyStyle.muted)
                    case .processing:
                        HStack { ProgressView(); Text("Making your chameleon…").font(RallyStyle.font(16, .semibold)) }
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

    /// FRONT · SIDE · BACK · SIDE, with the current one highlighted and finished ones ticked.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Self.steps.indices, id: \.self) { index in
                let done: Bool = {
                    if case .photo(let current, _) = capture.stage { return index < current }
                    return capture.stage == .processing || capture.stage == .done
                }()
                let current: Bool = { if case .photo(let now, _) = capture.stage { return now == index }; return false }()
                Text(done ? "✓ " + Self.steps[index].label : Self.steps[index].label)
                    .font(RallyStyle.font(12, .bold)).tracking(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(current ? RallyStyle.lime : done ? RallyStyle.mint : RallyStyle.surface.opacity(0.85), in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    private var framingHint: String {
        switch capture.framing {
        case .ready: "Got you! Hold still, it starts by itself."
        case .armsDown: "Hold your arms out a little, like the outline."
        case .notInView: "Walk back until your whole body fits. It starts by itself."
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
