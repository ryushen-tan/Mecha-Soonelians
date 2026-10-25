import AVFoundation
import SpriteKit
import XCTest
import SwiftUI
@testable import MechaSoonelians

final class JellyTests: XCTestCase {
    @MainActor func testLeaderboardRendersForVisualReview() async throws {
        let players = [
            Player(id: UUID(), name: "Ryushen Tan", avatar: 0, role: .seeker, isReady: true, points: 0, totalPoints: 480),
            Player(id: UUID(), name: "Bohan wang", avatar: 1, role: .hider, isReady: true, points: 120, totalPoints: 360),
            Player(id: UUID(), name: "Kai Song", avatar: 2, role: .hider, isReady: true, points: 40, totalPoints: 200)
        ]
        var state = GameState()
        state.phase = .results; state.players = players; state.roundNumber = 3
        state.seekerID = players[0].id; state.winnerIDs = [players[1].id]
        for (width, height, largeText) in [(320, 568, false), (375, 667, false), (414, 896, false), (768, 896, false), (375, 896, true)] {
            let session = GameSession(previewState: state, player: players[1], host: true)
            let view = GameView(session: session, onExit: {}, previewOnly: true)
                .environmentObject(JellyAudio())
                .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.rootViewController = UIHostingController(rootView: view)
            window.makeKeyAndVisible()
            window.rootViewController?.view.frame = window.bounds
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Leaderboard-\(width)-\(largeText ? "large-text" : "standard")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testSeekerShotFeedbackRendersForVisualReview() async throws {
        let seeker = Player(id: UUID(), name: "Bok", avatar: 0, role: .seeker, isReady: true)
        var state = GameState()
        state.phase = .seeking
        state.players = [seeker]
        state.seekerID = seeker.id
        state.secondsLeft = 150
        let session = GameSession(previewState: state, player: seeker, host: false)
        let view = GameView(session: session, onExit: {}, previewOnly: true, previewFound: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "Seeker-Found-Ya"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testSprayControlsRenderForVisualReview() async throws {
        let body = try XCTUnwrap(ChameleonBody.shared)
        for (width, height, largeText, poses) in [(320, 568, false, false), (375, 667, false, false), (414, 896, false, false), (768, 896, false, false), (375, 896, true, false), (320, 568, false, true), (375, 667, false, true), (414, 896, false, true), (768, 896, false, true), (375, 896, true, true)] {
            let size = CGSize(width: width, height: height)
            let painter = SprayPainter(previewBody: body, aimingAtBody: width == 320 || width == 414)
            let view = ZStack {
                JellyStyle.background.ignoresSafeArea()
                SprayPaintView(painter: painter, timeLeft: "4:03", onHide: {}, onCancel: {}, previewPoses: poses)
            }
            .environmentObject(JellyAudio())
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Spray-\(poses ? "poses" : "controls")-\(width)-\(largeText ? "large-text" : "standard")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testRoundPanelsRenderForVisualReview() async throws {
        let seeker = Player(id: UUID(), name: "Bohan wang", avatar: 0, role: .seeker, isReady: true)
        let hider = Player(id: UUID(), name: "Kai Song", avatar: 1, role: .hider, isReady: false, points: 120)
        let guest = Player(id: UUID(), name: "Ryushen Tan", avatar: 2, role: .hider, isReady: false, points: 40)
        for phase in [Phase.lobby, .hiding, .seeking, .results] {
            var state = GameState()
            state.phase = phase
            state.players = [seeker, hider, guest]
            state.seekerID = seeker.id
            state.secondsLeft = 266
            if phase == .results { state.winnerIDs = [hider.id] }
            state.ghosts = [Ghost(id: UUID(), ownerID: hider.id, transform: [], floorTransform: [],
                flushBack: false, hasModel: false, width: 0.5, height: 1, foundBy: nil)]
            for largeText in [false, true] {
                let player = phase == .seeking || phase == .hiding ? hider : seeker
                let session = GameSession(previewState: state, player: player, host: phase == .results || phase == .hiding)
                let view = GameView(session: session, onExit: {}, previewOnly: true)
                    .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                let host = UIHostingController(rootView: view)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(400))
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                window.isHidden = true
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "Round-\(phase.rawValue)-\(largeText ? "large-text" : "standard")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor func testBundledReferenceAssetsAndFontsAreUsableOffline() throws {
        for pose in 1...8 {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "pose-\(pose)", withExtension: "png", subdirectory: "JellyAssets/sprites"))
            XCTAssertNotNil(UIImage(contentsOfFile: url.path))
        }
        let music = try XCTUnwrap(Bundle.main.url(forResource: "bgm", withExtension: "mp3", subdirectory: "JellyAssets/audio"))
        XCTAssertGreaterThan(try AVAudioPlayer(contentsOf: music).duration, 1)
        XCTAssertNotNil(UIFont(name: "Outfit-Thin_ExtraBold", size: 24))
        XCTAssertNotNil(UIFont(name: "Nunito-Regular", size: 18))
    }

    @MainActor func testReducedMotionHasImmediateVisiblePlayAndRefillsAtDifferentSizes() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 402, height: 874), CGSize(width: 1024, height: 768)] {
            let state = JellySceneState()
            state.scene.size = size
            state.scene.configure(reducedMotion: true, suspended: false)
            XCTAssertTrue(state.filled)
            XCTAssertGreaterThan(state.count, 20)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(state.playPosition.frame))
            let originalCount = state.count
            state.scene.refill()
            XCTAssertEqual(state.count, originalCount, "Refill must replace the pile, not accumulate bodies")
            XCTAssertFalse(state.tiltEnabled)
        }
    }
}
