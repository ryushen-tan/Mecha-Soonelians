import AVFoundation
import SwiftUI

@MainActor
final class JellyAudio: ObservableObject {
    enum Key: CaseIterable { case click, type, enter }
    @Published private(set) var muted = UserDefaults.standard.bool(forKey: "mecha.muted")
    private var music: AVAudioPlayer?
    private var keys: [Key: AVAudioPlayer] = [:]
    private var wantsMusic = false
    private var active = true

    init() {
        // Ambient audio respects the silent switch and other apps' music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        if let url = Bundle.main.url(forResource: "bgm", withExtension: "mp3", subdirectory: "JellyAssets/audio") {
            music = try? AVAudioPlayer(contentsOf: url)
            music?.numberOfLoops = -1
            music?.volume = 0.5
            music?.prepareToPlay()
        }
        for kind in Key.allCases { keys[kind] = try? AVAudioPlayer(data: Self.clickData(kind)) }
    }

    func toggleMute() {
        muted.toggle()
        UserDefaults.standard.set(muted, forKey: "mecha.muted")
        updatePlayback()
    }

    func setActive(_ active: Bool) { self.active = active; updatePlayback() }
    func startMusic() { wantsMusic = true; updatePlayback() }
    func restartPour() { wantsMusic = false; music?.stop(); music?.currentTime = 0 }

    func key(_ kind: Key) {
        guard !muted, active, let player = keys[kind] else { return }
        player.currentTime = 0
        player.play()
    }

    private func updatePlayback() {
        if active && !muted && wantsMusic { music?.play() } else { music?.pause() }
        if muted || !active { keys.values.forEach { $0.stop() } }
    }

    /// The noise burst and descending sine from variants/sfx.js, rendered once as PCM.
    private static func clickData(_ kind: Key) -> Data {
        let parameters: (Double, Double, Double, Double)
        switch kind {
        case .click: parameters = (2600, 260, 0.06, 0.35)
        case .type: parameters = (3200, 330, 0.045, 0.28)
        case .enter: parameters = (1500, 170, 0.09, 0.5)
        }
        let (frequency, body, duration, gain) = parameters
        let rate = 44_100.0
        let count = Int(rate * max(duration, 0.06))
        let omega = 2 * Double.pi * frequency / rate
        let alpha = sin(omega) / (2 * 0.8)
        let a0 = 1 + alpha
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0, phase = 0.0
        var samples = Data()
        for i in 0..<count {
            let t = Double(i) / rate
            let envelope = pow(max(0, 1 - t / duration), 2.5)
            let noise = Double.random(in: -1...1) * envelope
            let filtered = (alpha * noise - alpha * x2 + 2 * cos(omega) * y1 - (1 - alpha) * y2) / a0
            x2 = x1; x1 = noise; y2 = y1; y1 = filtered
            phase += 2 * Double.pi * body * pow(0.5, min(t / 0.04, 1)) / rate
            let thock = sin(phase) * 0.22 * pow(0.001 / 0.22, t / 0.05)
            let sample = min(1, max(-1, filtered * gain * exp(-t * 60) + thock))
            var value = Int16(sample * 32767).littleEndian
            withUnsafeBytes(of: &value) { samples.append(contentsOf: $0) }
        }
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + samples.count)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(rate))
        number(UInt32(rate * 2)); number(UInt16(2)); number(UInt16(16))
        text("data"); number(UInt32(samples.count)); data.append(samples)
        return data
    }
}
